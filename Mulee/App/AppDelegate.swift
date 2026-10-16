import AppKit
import AppIntents
import MuleeCore

/// 菜单栏常驻，并在退出前给下载引擎最多五秒保存会话。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private(set) lazy var updates = AppUpdateController.shared
    var openURLRouter: OpenURLRouter? {
        didSet { drainPendingOpenURLs() }
    }
    private var pendingOpenURLs: [[URL]] = []
    private var singleInstanceSession: SingleInstanceSession?
    private var singleInstanceHandoff: SingleInstanceHandoff?
    private var handoffTask: Task<Void, Never>?
    private var servicesProvider: DownloadServicesProvider?
    private var settingsRuntime: SettingsRuntime?
    private var diskReserveMonitor: DiskReserveMonitor?
    private var notificationService: NotificationService?
    private var whenAllDoneController: WhenAllDoneController?
    private var slowModeController: SlowModeController?
    private var transferScheduleController: TransferScheduleController?
    private var coordinator: DownloadCoordinator?
    private var extractionCoordinator: ExtractionCoordinator?
    private var startupTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var settings: SettingsModel?
    private var model: AppModel?
    private var isTerminating = false
    private var hasReplied = false
    private let shutdownProgress = ShutdownProgressController()

    func configureSingleInstance(
        _ session: SingleInstanceSession,
        send: @escaping @MainActor ([URL], pid_t) async -> Void = SingleInstanceHandoff.send,
        activate: @escaping @MainActor (pid_t) -> Void = SingleInstanceHandoff.activate,
        terminate: @escaping @MainActor () -> Void = { NSApp.terminate(nil) }
    ) {
        singleInstanceSession = session
        guard !session.isPrimary else { return }
        let handoff = SingleInstanceHandoff(session: session, send: send, activate: activate, terminate: terminate)
        singleInstanceHandoff = handoff
        for urls in pendingOpenURLs { handoff.receive(urls) }
        pendingOpenURLs.removeAll()
    }

    func finishSingleInstanceHandoff() async {
        await singleInstanceHandoff?.finish()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let singleInstanceHandoff {
            singleInstanceHandoff.receive(urls)
            return
        }
        pendingOpenURLs.append(urls)
        drainPendingOpenURLs()
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        application(sender, open: filenames.map { URL(filePath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    private func drainPendingOpenURLs() {
        guard singleInstanceHandoff == nil else { return }
        guard let openURLRouter else { return }
        let pending = pendingOpenURLs
        pendingOpenURLs.removeAll()
        for urls in pending { openURLRouter.open(urls) }
    }

    func configure(model: AppModel, settings: SettingsModel, usesSampleData: Bool) {
        guard singleInstanceSession?.isPrimary != false else { return }
        openURLRouter = OpenURLRouter(model: model, settings: settings)
        servicesProvider = DownloadServicesProvider(router: openURLRouter)
        self.model = model
        self.settings = settings
        let intentActions = MuleeIntentActions(model: model)
        // 系统可能在后台队列解析依赖；异步 Sendable 工厂不会捕获主线程隔离的同步自动闭包。
        let intentProvider: @Sendable () async -> MuleeIntentActions = { intentActions }
        AppDependencyManager.shared.add(dependency: intentProvider)
        updates.installation.hasActiveTransfers = { [weak model] in
            guard let model else { return false }
            return model.hasActiveTransfers || model.tasks.contains { [.queued, .waitingForSources].contains($0.status) }
        }
        updates.installation.confirm = Self.confirmUpdateInstallation
        updates.installationDidAbort = { [weak self] in
            guard let self, !isTerminating else { return }
            shutdownProgress.finish(restoreWindows: true)
        }
        updates.installation.prepare = { [weak self] in
            await self?.prepareForUpdate() ?? false
        }
        // 示例数据模式和单元测试宿主都不启动真实引擎。
        guard !usesSampleData, !AppEnvironment.isRunningUnitTests, coordinator == nil else { return }
        NetworkDiagnosticsService.shared.start(model: model)
        model.loadTaskHistory(from: TaskHistoryStore())
        model.transferStatistics = TransferStatisticsStore(
            fileURL: URL.applicationSupportDirectory.appending(path: "Mulee/statistics.json")
        )
        model.transferStatistics?.record(tasks: model.tasks)
        model.loadUnzipRules(from: UnzipRuleStore())
        let stateDirectory = URL.applicationSupportDirectory.appending(path: "Mulee/aria2", directoryHint: .isDirectory)
        let torrent = TorrentEngine(
            stateDirectory: URL.applicationSupportDirectory.appending(path: "Mulee/torrent", directoryHint: .isDirectory),
            settings: BitTorrentEngineConfiguration.configuration(from: settings)
        )
        model.bitTorrent = BitTorrentController(
            engine: torrent, model: model, configuration: BitTorrentEngineConfiguration.configuration(from: settings)
        )
        model.publicTrackers = PublicTrackerController(
            service: PublicTrackerSubscriptionService(fileURL: URL.applicationSupportDirectory.appending(path: "Mulee/public-trackers.json")),
            engine: torrent, settings: settings
        )
        model.publicTrackers?.start()
        let ed2k = Ed2kEngine(
            stateDirectory: URL.applicationSupportDirectory.appending(path: "Mulee/amule", directoryHint: .isDirectory),
            settings: Ed2kEngineConfiguration.configuration(from: settings)
        )
        model.ed2k = Ed2kController(
            engine: ed2k, model: model, configuration: Ed2kEngineConfiguration.configuration(from: settings)
        )
        coordinator = DownloadCoordinator(
            model: model, engines: [Aria2Engine(stateDirectory: stateDirectory), torrent, ed2k],
            videoBootstrap: VideoEngineBootstrap()
        )
        notificationService = NotificationService(model: model, settings: settings)
        diskReserveMonitor = DiskReserveMonitor(model: model, settings: settings)
        whenAllDoneController = WhenAllDoneController(model: model, settings: settings)
        slowModeController = SlowModeController(model: model, settings: settings)
        transferScheduleController = TransferScheduleController(model: model, settings: settings)
        slowModeController?.start()
        extractionCoordinator = ExtractionCoordinator(
            model: model, settings: settings,
            extractor: ArchiveExtractionService(passwords: model.extractionPasswords)
        )
        extractionCoordinator?.start()
        let runtime = SettingsRuntime(model: model, settings: settings) { [weak model] options in
            model?.coordinator?.apply(options: options)
        }
        settingsRuntime = runtime
        model.settingsRuntime = runtime
        runtime.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if singleInstanceHandoff != nil {
            NSApp.setActivationPolicy(.prohibited)
            handoffTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(2)) }
                catch { return }
                await self?.finishSingleInstanceHandoff()
            }
            return
        }
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        if !AppEnvironment.isRunningUnitTests, !Self.wasLaunchedAtLogin {
            model?.mainWindowRequest += 1
        }
        updates.startAutomaticChecks()
        guard let coordinator, let settings else { return }
        startupTask = Task {
            await coordinator.start(
                options: EngineOptionsMapper.options(from: settings, slowMode: model?.isSlowModeActive ?? false),
                videoConfiguration: VideoEngineConfiguration.configuration(from: settings)
            )
            if !Task.isCancelled {
                diskReserveMonitor?.start()
                transferScheduleController?.start()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        handoffTask?.cancel()
        openURLRouter?.stopCookieCleanup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(settings?.closeKeepsRunning ?? true)
    }

    static var wasLaunchedAtLogin: Bool {
        isLoginLaunch(NSAppleEventManager.shared().currentAppleEvent)
    }

    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard singleInstanceHandoff == nil else { return false }
        guard !isTerminating, !shutdownProgress.isActive else { return false }
        model?.mainWindowRequest += 1
        return false
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let count = NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue == "mulee-main" }.count
        if WindowClosePolicy.shouldQuit(closeKeepsRunning: settings?.closeKeepsRunning ?? true, mainWindowCount: count) {
            NSApp.terminate(nil)
            return false
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if singleInstanceHandoff != nil { return .terminateNow }
        if updates.installation.isPrepared { return .terminateNow }
        if updates.installationPending {
            guard updates.installation.mayInstall() else { return .terminateCancel }
            guard !isTerminating else { return .terminateLater }
            isTerminating = true
            shutdownTask = Task {
                let prepared = await updates.installation.prepareForInstallation()
                isTerminating = false
                sender.reply(toApplicationShouldTerminate: prepared)
            }
            return .terminateLater
        }
        guard let coordinator else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        if let model, !model.isPerformingWhenAllDone, WindowClosePolicy.needsConfirmation(tasks: model.tasks) {
            let alert = NSAlert()
            alert.messageText = String(localized: "还有任务正在运行，确定退出 Mulee？")
            alert.informativeText = String(localized: "退出会暂停下载和解压，下载进度会保留。")
            alert.addButton(withTitle: String(localized: "取消"))
            alert.addButton(withTitle: String(localized: "退出"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        isTerminating = true
        shutdownProgress.begin()
        settingsRuntime?.stop()
        diskReserveMonitor?.stop()
        notificationService?.stop()
        whenAllDoneController?.cancel()
        slowModeController?.stop()
        transferScheduleController?.stop()
        model?.transferStatistics?.save()
        NetworkDiagnosticsService.shared.stop()
        startupTask?.cancel()
        extractionCoordinator?.cancel()
        model?.flushTaskHistory()
        shutdownTask = Task { [weak self] in
            await self?.extractionCoordinator?.stop()
            await coordinator.stop()
            self?.finishTermination(sender)
        }
        // 不使用 task group 竞速：不响应取消的 stop 不能拖延五秒上限。
        timeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            self?.finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ application: NSApplication) {
        guard !hasReplied else { return }
        hasReplied = true
        model?.flushTaskHistory()
        model?.transferStatistics?.save()
        timeoutTask?.cancel()
        shutdownProgress.finish()
        application.reply(toApplicationShouldTerminate: true)
    }

    /// 更新不走普通退出的五秒兜底，必须等引擎保存会话并停止后才允许安装。
    private func prepareForUpdate() async -> Bool {
        transferScheduleController?.stop()
        model?.transferStatistics?.save()
        diskReserveMonitor?.stop()
        notificationService?.stop()
        whenAllDoneController?.cancel()
        slowModeController?.stop()
        shutdownProgress.begin()
        NetworkDiagnosticsService.shared.stop()
        startupTask?.cancel()
        await startupTask?.value
        extractionCoordinator?.cancel()
        await extractionCoordinator?.stop()
        await coordinator?.stop()
        model?.flushTaskHistory()
        model?.transferStatistics?.save()
        let saved = model?.taskHistoryIssue == nil
        if !saved { shutdownProgress.finish(restoreWindows: true) }
        return saved
    }

    private static func confirmUpdateInstallation() -> Bool {
        let alert = NSAlert()
        alert.messageText = String(localized: "仍有任务正在进行，要安装更新吗？")
        alert.informativeText = String(localized: "Mulee 将保存下载进度并退出，安装更新后重新打开。")
        alert.addButton(withTitle: String(localized: "安装并重新打开"))
        alert.addButton(withTitle: String(localized: "稍后"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}

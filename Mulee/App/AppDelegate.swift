import AppKit
import MuleeCore

/// 菜单栏常驻，并在退出前给下载引擎最多五秒保存会话。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let updates = AppUpdateController.shared
    var openURLRouter: OpenURLRouter?
    private var coordinator: DownloadCoordinator?
    private var extractionCoordinator: ExtractionCoordinator?
    private var startupTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var settings: SettingsModel?
    private var model: AppModel?
    private var isTerminating = false
    private var hasReplied = false

    func configure(model: AppModel, settings: SettingsModel, usesSampleData: Bool) {
        openURLRouter = OpenURLRouter(model: model, settings: settings)
        updates.installation.hasActiveTransfers = { [weak model] in
            guard let model else { return false }
            return model.hasActiveTransfers || model.tasks.contains { [.queued, .waitingForSources].contains($0.status) }
        }
        updates.installation.confirm = Self.confirmUpdateInstallation
        updates.installation.prepare = { [weak self] in
            await self?.prepareForUpdate() ?? false
        }
        // 示例数据模式和单元测试宿主都不启动真实引擎。
        guard !usesSampleData, !AppEnvironment.isRunningUnitTests, coordinator == nil else { return }
        self.model = model
        NetworkDiagnosticsService.shared.start(model: model)
        model.loadTaskHistory(from: TaskHistoryStore())
        model.loadUnzipRules(from: UnzipRuleStore())
        self.settings = settings
        let stateDirectory = URL.applicationSupportDirectory.appending(path: "Mulee/aria2", directoryHint: .isDirectory)
        let torrent = TorrentEngine(
            stateDirectory: URL.applicationSupportDirectory.appending(path: "Mulee/torrent", directoryHint: .isDirectory),
            settings: BitTorrentEngineConfiguration.configuration(from: settings)
        )
        model.bitTorrent = BitTorrentController(
            engine: torrent, model: model, configuration: BitTorrentEngineConfiguration.configuration(from: settings)
        )
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
        extractionCoordinator = ExtractionCoordinator(
            model: model, settings: settings,
            extractor: ArchiveExtractionService(passwords: model.extractionPasswords)
        )
        extractionCoordinator?.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        updates.startAutomaticChecks()
        guard let coordinator, let settings else { return }
        startupTask = Task {
            await coordinator.start(
                options: EngineOptionsMapper.options(from: settings),
                videoConfiguration: VideoEngineConfiguration.configuration(from: settings)
            )
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
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
        isTerminating = true
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
        timeoutTask?.cancel()
        application.reply(toApplicationShouldTerminate: true)
    }

    /// 更新不走普通退出的五秒兜底，必须等引擎保存会话并停止后才允许安装。
    private func prepareForUpdate() async -> Bool {
        NetworkDiagnosticsService.shared.stop()
        startupTask?.cancel()
        await startupTask?.value
        extractionCoordinator?.cancel()
        await extractionCoordinator?.stop()
        await coordinator?.stop()
        model?.flushTaskHistory()
        return model?.taskHistoryIssue == nil
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

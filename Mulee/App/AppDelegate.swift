import AppKit
import MuleeCore

/// 菜单栏常驻，并在退出前给下载引擎最多五秒保存会话。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var openURLRouter: OpenURLRouter?
    private var servicesProvider: DownloadServicesProvider?
    private var settingsRuntime: SettingsRuntime?
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
        servicesProvider = DownloadServicesProvider(router: openURLRouter)
        self.model = model
        self.settings = settings
        // 示例数据模式和单元测试宿主都不启动真实引擎。
        guard !usesSampleData, !AppEnvironment.isRunningUnitTests, coordinator == nil else { return }
        NetworkDiagnosticsService.shared.start(model: model)
        model.loadTaskHistory(from: TaskHistoryStore())
        model.loadUnzipRules(from: UnzipRuleStore())
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
        let runtime = SettingsRuntime(model: model, settings: settings) { [weak model] options in
            model?.coordinator?.apply(options: options)
        }
        settingsRuntime = runtime
        model.settingsRuntime = runtime
        runtime.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = servicesProvider
        NSUpdateDynamicServices()
        if !AppEnvironment.isRunningUnitTests, !Self.wasLaunchedAtLogin {
            model?.mainWindowRequest += 1
        }
        guard let coordinator, let settings else { return }
        startupTask = Task {
            await coordinator.start(
                options: EngineOptionsMapper.options(from: settings),
                videoConfiguration: VideoEngineConfiguration.configuration(from: settings)
            )
        }
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
        guard !isTerminating else { return .terminateLater }
        if let model, WindowClosePolicy.needsConfirmation(tasks: model.tasks) {
            let alert = NSAlert()
            alert.messageText = String(localized: "还有任务正在运行，确定退出 Mulee？")
            alert.informativeText = String(localized: "退出会暂停下载和解压，下载进度会保留。")
            alert.addButton(withTitle: String(localized: "取消"))
            alert.addButton(withTitle: String(localized: "退出"))
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        settingsRuntime?.stop()
        guard let coordinator else { return .terminateNow }
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
}

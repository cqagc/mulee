import AppKit
import MuleeCore

/// 菜单栏常驻，并在退出前给下载引擎最多五秒保存会话。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
        coordinator = DownloadCoordinator(
            model: model, engines: [Aria2Engine(stateDirectory: stateDirectory), torrent],
            videoBootstrap: VideoEngineBootstrap()
        )
        extractionCoordinator = ExtractionCoordinator(
            model: model, settings: settings,
            extractor: ArchiveExtractionService(passwords: model.extractionPasswords)
        )
        extractionCoordinator?.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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
}

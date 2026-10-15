import AppKit
import MuleeCore

/// 菜单栏常驻，并在退出前给下载引擎最多五秒保存会话。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: DownloadCoordinator?
    private var startupTask: Task<Void, Never>?
    private var shutdownTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var settings: SettingsModel?
    private var isTerminating = false
    private var hasReplied = false

    func configure(model: AppModel, settings: SettingsModel, usesSampleData: Bool) {
        guard !usesSampleData, coordinator == nil else { return }
        self.settings = settings
        let stateDirectory = URL.applicationSupportDirectory.appending(path: "Mulee/aria2", directoryHint: .isDirectory)
        coordinator = DownloadCoordinator(model: model, engines: [Aria2Engine(stateDirectory: stateDirectory)])
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let coordinator, let settings else { return }
        startupTask = Task {
            await coordinator.start(options: EngineOptionsMapper.options(from: settings))
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        guard !isTerminating else { return .terminateLater }
        isTerminating = true
        startupTask?.cancel()
        shutdownTask = Task { [weak self] in
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
        timeoutTask?.cancel()
        application.reply(toApplicationShouldTerminate: true)
    }
}

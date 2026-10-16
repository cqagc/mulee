import Foundation
import MuleeCore

/// 生命周期跟随 App，不依赖主窗口是否可见。
final class SettingsRuntime {
    private let model: AppModel
    private let settings: SettingsModel
    private let now: () -> Date
    private let applyOptions: (EngineOptions) -> Void
    private let clipboard: ClipboardWatcher
    private var worker: Task<Void, Never>?
    private var previousOptions: EngineOptions?

    init(
        model: AppModel, settings: SettingsModel,
        pasteboard: any ClipboardReading = SystemClipboard(), now: @escaping () -> Date = Date.init,
        applyOptions: @escaping (EngineOptions) -> Void
    ) {
        self.model = model
        self.settings = settings
        model.downloadSettings = settings
        self.now = now
        self.applyOptions = applyOptions
        clipboard = ClipboardWatcher(pasteboard: pasteboard) { [weak model] links in
            model?.showNewTask(prefill: links.map(\.original).joined(separator: "\n"))
        }
    }

    isolated deinit { worker?.cancel() }

    func start() {
        guard worker == nil else { return }
        refresh()
        worker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        worker?.cancel()
        worker = nil
        clipboard.setEnabled(false)
    }

    func refresh() {
        let date = now()
        model.purgeExpiredTrash(now: date)
        model.slowModeController?.refresh()
        model.whenAllDoneController?.settingsDidChange()
        model.whenAllDoneController?.refresh()
        model.notificationService?.flushCompletionsIfDue()
        clipboard.setEnabled(settings.watchClipboard)
        model.preventsSleepWhileDownloading = settings.preventSleep
        model.allowsSleepWhenDone = settings.allowSleepWhenDone
        model.isScheduledLimitActive = ScheduledSpeedLimit.isActive(settings: settings, now: date)
        let options = EngineOptionsMapper.options(from: settings, now: date, slowMode: model.isSlowModeActive)
        if options != previousOptions {
            previousOptions = options
            applyOptions(options)
        }
    }
}

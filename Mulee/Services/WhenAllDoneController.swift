import AppKit
import IOKit.pwr_mgt
import MuleeCore
import SwiftUI

/// 主动睡眠与原有「允许系统空闲睡眠」偏好分开保存。
enum WhenAllDoneAction: String, CaseIterable, Identifiable {
    case none, sleep, shutdown, quit

    var id: Self { self }

    var title: String {
        switch self {
        case .none: String(localized: "不执行操作")
        case .sleep: String(localized: "睡眠")
        case .shutdown: String(localized: "关机")
        case .quit: String(localized: "退出 Mulee")
        }
    }
}

@MainActor
final class WhenAllDoneController {
    private let model: AppModel
    private let settings: SettingsModel
    private let now: () -> Date
    private let execute: @MainActor (WhenAllDoneAction) throws -> Void
    private let showsPanel: Bool
    private var configuredAction: WhenAllDoneAction
    private var tracked: Set<DownloadTask.ID> = []
    private var known: Set<DownloadTask.ID> = []
    private var deadline: Date?
    private var panel: NSPanel?
    private var inputMonitor: Any?
    private var isRefreshing = false

    init(
        model: AppModel, settings: SettingsModel, now: @escaping () -> Date = Date.init,
        showsPanel: Bool = true,
        execute: @escaping @MainActor (WhenAllDoneAction) throws -> Void = WhenAllDoneController.performSystemAction
    ) {
        self.model = model
        self.settings = settings
        self.now = now
        self.showsPanel = showsPanel
        self.execute = execute
        configuredAction = settings.whenAllDone
        model.whenAllDoneController = self
        select(settings.whenAllDone)
    }

    isolated deinit {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        panel?.orderOut(nil)
    }

    func settingsDidChange() {
        guard configuredAction != settings.whenAllDone else { return }
        configuredAction = settings.whenAllDone
        select(configuredAction)
    }

    func select(_ action: WhenAllDoneAction) {
        dismissCountdown()
        model.whenAllDoneAction = action
        known = Set(model.activeTasks.map(\.id))
        tracked = Set(model.activeTasks.filter {
            [.downloading, .queued, .waitingForSources, .extracting, .postProcessing].contains($0.status)
                || $0.postDownload.extractionState == .queued
        }.map(\.id))
    }

    func refresh() {
        guard !isRefreshing, model.whenAllDoneAction != .none else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let ids = Set(model.activeTasks.map(\.id))
        let added = ids.subtracting(known)
        known = ids
        if !added.isEmpty {
            tracked.formUnion(added)
            dismissCountdown()
        }
        let tasks = model.activeTasks.filter { tracked.contains($0.id) }
        guard !tasks.isEmpty else {
            dismissCountdown()
            return
        }
        let date = now()
        guard tasks.allSatisfy({ Self.isDone($0, now: date) }) else {
            dismissCountdown()
            return
        }
        if deadline == nil {
            deadline = date.addingTimeInterval(60)
            model.notificationService?.sendSystem(
                title: String(localized: "下载已全部完成"),
                body: String(localized: "60 秒后将\(model.whenAllDoneAction.title)，可在 Mulee 中取消。"), countdown: true
            )
            if showsPanel { presentCountdown() }
        }
        guard let deadline else { return }
        model.whenAllDoneSecondsRemaining = max(0, Int(ceil(deadline.timeIntervalSince(date))))
        guard date >= deadline else { return }
        let action = model.whenAllDoneAction
        cancel()
        do {
            model.isPerformingWhenAllDone = [.shutdown, .quit].contains(action)
            model.flushTaskHistory()
            try execute(action)
        } catch {
            model.isPerformingWhenAllDone = false
            model.notificationService?.sendSystem(
                title: String(localized: "下完后操作未执行"), body: error.localizedDescription
            )
        }
    }

    func userDidInteract() {
        model.isPerformingWhenAllDone = false
        if deadline != nil { cancel() }
    }

    func cancel() {
        dismissCountdown()
        model.whenAllDoneAction = .none
        tracked.removeAll()
    }

    private func dismissCountdown() {
        if deadline != nil { model.notificationService?.cancelCountdown() }
        deadline = nil
        model.whenAllDoneSecondsRemaining = nil
        panel?.orderOut(nil)
        panel = nil
        if let inputMonitor {
            NSEvent.removeMonitor(inputMonitor)
            self.inputMonitor = nil
        }
    }

    private func presentCountdown() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 188),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false
        )
        panel.title = String(localized: "本次下完后")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.contentView = NSHostingView(rootView: WhenAllDoneCountdownView(model: model) { [weak self] in self?.cancel() })
        self.panel = panel
        panel.center()
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .created)
        inputMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.userDidInteract() }
            return event
        }
    }

    static func isDone(_ task: DownloadTask, now: Date) -> Bool {
        if task.status == .seeding { return true }
        if task.kind == .ed2k, task.status == .waitingForSources,
           case .ed2k(_, let info) = task.detail, now.timeIntervalSince(info.waitingSince) > 86_400 {
            return true
        }
        return task.status == .completed && ![.queued, .extracting].contains(task.postDownload.extractionState)
    }

    static func performSystemAction(_ action: WhenAllDoneAction) throws {
        switch action {
        case .none:
            break
        case .quit:
            NSApp.terminate(nil)
        case .sleep:
            let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
            guard port != 0 else { throw CocoaError(.featureUnsupported) }
            defer { IOServiceClose(port) }
            let result = IOPMSleepSystem(port)
            guard result == kIOReturnSuccess else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(result), userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "系统未允许睡眠，请检查电源设置。")
                ])
            }
        case .shutdown:
            var error: NSDictionary?
            guard let script = NSAppleScript(source: "tell application \"System Events\" to shut down") else {
                throw CocoaError(.featureUnsupported)
            }
            script.executeAndReturnError(&error)
            if let error {
                let reason = error[NSAppleScript.errorMessage] as? String ?? String(localized: "系统未授权自动化操作")
                throw NSError(domain: "WhenAllDone", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: String(localized: "无法关机：\(reason)。请在系统设置中允许 Mulee 控制系统事件。")
                ])
            }
        }
    }
}

private struct WhenAllDoneCountdownView: View {
    let model: AppModel
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("下载已全部完成").font(.headline)
            Text("\(model.whenAllDoneSecondsRemaining ?? 60) 秒后将\(model.whenAllDoneAction.title)")
                .monospacedDigit()
            Text("加入新任务或操作 Mulee 将取消倒计时。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("取消", action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

import MuleeCore
import SwiftUI

/// 在 Debug 构建里执行 DebugLaunchOptions 指定的启动动作；Release 构建里什么都不做。
struct DebugLaunchModifier: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        #if DEBUG
        content
            .preferredColorScheme(DebugLaunchOptions.colorScheme)
            .task(applyLaunchOptions)
        #else
        content
        #endif
    }

    #if DEBUG
    private static var didAddLaunchLinks = false

    private func applyLaunchOptions() async {
        if DebugLaunchOptions.stressTaskCount > 0 {
            await runStressTasks(count: DebugLaunchOptions.stressTaskCount)
            return
        }
        if DebugLaunchOptions.usesProxiedNetwork {
            model.networkStatus = MockData.proxiedNetwork
        }
        if DebugLaunchOptions.showsNewTask {
            model.showNewTask(prefill: DebugLaunchOptions.samplePasteText)
        }
        if DebugLaunchOptions.opensSettings {
            openSettings()
        }
        if DebugLaunchOptions.showsMenuBarPanelWindow {
            openWindow(id: "menu-bar-panel-preview")
        }
        if DebugLaunchOptions.showsIconGallery {
            openWindow(id: "file-icon-gallery")
        }
        if let text = DebugLaunchOptions.linksToAdd, !Self.didAddLaunchLinks {
            Self.didAddLaunchLinks = true
            // 等待所需引擎就绪；慢启动不能把端到端任务误记为引擎未运行。
            let kinds = Set(LinkParser.parse(text).map(\.kind))
            for _ in 0..<120 {
                if kinds.allSatisfy({ model.engineStates[$0] == .running }) { break }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
            model.addTasks(from: LinkParser.parse(text), autoExtract: settings.autoExtract)
        }
    }

    private func runStressTasks(count: Int) async {
        let templates = TaskKind.allCases.compactMap { kind in MockData.tasks.first { $0.kind == kind } }
        let statuses: [TaskStatus] = [.downloading, .queued, .waitingForSources, .paused, .completed,
                                      .failed, .engineUnavailable, .extracting, .postProcessing, .seeding]
        model.preventsSleepWhileDownloading = false
        model.tasks = (0..<count).map { index in
            let template = templates[index % templates.count]
            var status = statuses[(index / templates.count) % statuses.count]
            if status == .seeding && template.kind != .bittorrent { status = .completed }
            return DownloadTask(
                name: "Mulee Fictional Resource \(index + 1).\(template.fileExtension ?? "zip")",
                fileExtension: template.fileExtension, kind: template.kind, status: status,
                totalBytes: 10_000_000_000, receivedBytes: Int64(index % 90) * 100_000_000,
                downloadRate: status == .downloading ? 1_000_000 : 0,
                uploadRate: status == .seeding ? 100_000 : 0,
                completedAt: status == .completed ? .now : nil, detail: template.detail,
                postDownload: PostDownloadInfo(autoExtract: false),
                sourceLink: "https://example.com/fictional/\(index)", engineTaskID: "stress-\(index)"
            )
        }
        model.selectedTaskID = nil
        let monitor = Task { await monitorStressResponsiveness() }
        defer { monitor.cancel() }
        while NSApp.windows.first(where: { $0.identifier?.rawValue == "mulee-main" && $0.isVisible }) == nil {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
        }
        await Task.yield()
        let window = NSApp.windows.first { $0.identifier?.rawValue == "mulee-main" }
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.displayIfNeeded()
        NSLog("MuleeStress ready count=%d uptime=%.6f", count, ProcessInfo.processInfo.systemUptime)
        let clock = ContinuousClock()
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            let started = clock.now
            let snapshots = Dictionary(grouping: model.tasks, by: \.kind).mapValues { tasks in
                tasks.map { task in
                    EngineTaskSnapshot(
                        engineTaskID: task.engineTaskID ?? "", name: task.name,
                        totalBytes: task.totalBytes,
                        receivedBytes: task.status == .downloading
                            ? (task.receivedBytes + task.downloadRate) % 10_000_000_000 : task.receivedBytes,
                        downloadRate: task.downloadRate, uploadRate: task.uploadRate, status: task.status,
                        connections: 8, savePath: nil, sourceURL: nil, errorMessage: nil,
                        detail: task.detail, completedAt: task.completedAt
                    )
                }
            }
            // 和 DownloadCoordinator 的真实轮询一样合并快照，再整体发布值类型数组。
            model.tasks = EngineSnapshotMerger.merge(tasks: model.tasks, snapshots: snapshots, now: .now)
            model.downloadRateHistory = EngineSnapshotMerger.appendingRate(model.totalDownloadRate, to: model.downloadRateHistory)
            NSLog("MuleeStress refresh seconds=%@", String(describing: started.duration(to: clock.now)))
        }
    }

    private func monitorStressResponsiveness() async {
        let clock = ContinuousClock()
        var maximum = Duration.zero
        var report = clock.now
        var direction: CGFloat = 1
        let scrollingStarts = clock.now.advanced(by: .seconds(15))
        var didStartScrolling = false
        while !Task.isCancelled {
            let deadline = clock.now.advanced(by: .milliseconds(50))
            do { try await clock.sleep(until: deadline) } catch { return }
            maximum = max(maximum, deadline.duration(to: clock.now))
            if DebugLaunchOptions.stressScrolls, clock.now >= scrollingStarts,
               let content = NSApp.windows.first(where: { $0.identifier?.rawValue == "mulee-main" })?.contentView,
               let scroll = stressListScrollView(in: content), let document = scroll.documentView {
                if !didStartScrolling {
                    NSLog("MuleeStress scroll-start")
                    didStartScrolling = true
                }
                let limit = max(0, document.bounds.height - scroll.contentView.bounds.height)
                let position = scroll.contentView.bounds.origin.y + 120 * direction
                if position >= limit { direction = -1 }
                if position <= 0 { direction = 1 }
                document.scroll(NSPoint(x: 0, y: min(limit, max(0, position))))
            }
            if report.duration(to: clock.now) >= .seconds(5) {
                NSLog("MuleeStress main-thread-lag max=%@", String(describing: maximum))
                maximum = .zero
                report = clock.now
            }
        }
    }

    private func stressListScrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView, scroll.documentView?.bounds.height ?? 0 > 2000 {
            return scroll
        }
        for child in view.subviews {
            if let scroll = stressListScrollView(in: child) { return scroll }
        }
        return nil
    }
    #endif
}

extension View {
    /// 挂在主窗口根视图上，处理 Debug 启动参数。
    func debugLaunchOptions() -> some View {
        modifier(DebugLaunchModifier())
    }
}

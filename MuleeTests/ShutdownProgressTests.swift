import AppKit
import Testing
@testable import Mulee

@Suite(.serialized)
@MainActor
struct ShutdownProgressTests {
    @Test("退出立即收起窗口，超过延迟才显示原生非模态面板")
    func delayedFeedback() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        let feedback = ShutdownProgressController()
        defer {
            feedback.finish()
            window.orderOut(nil)
        }
        feedback.begin(windows: [window], delay: .milliseconds(20))
        #expect(!window.isVisible)
        #expect(feedback.panel == nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while feedback.panel == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let panel = try #require(feedback.panel)
        #expect(panel.isVisible)
        #expect(panel.isFloatingPanel)
        #expect(!panel.styleMask.contains(.closable))
        #expect(NSApp.modalWindow !== panel)
        #expect(panel.title == String(localized: "正在退出 Mulee"))
        feedback.finish(restoreWindows: true)
        #expect(window.isVisible)
        #expect(!panel.isVisible)
        #expect(!feedback.isActive)
    }

    @Test("更新中止恢复窗口并清除退出反馈，不改变 Sparkle 的准备状态管理")
    func abortedUpdateRestoresFeedback() async {
        let updater = AppUpdateUpdaterStub()
        let updates = AppUpdateController(updater: updater)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let feedback = ShutdownProgressController()
        updates.installationDidAbort = { feedback.finish(restoreWindows: true) }
        updates.installation.prepare = {
            feedback.begin(windows: [window])
            return true
        }
        #expect(await updates.installation.prepareForInstallation())
        #expect(feedback.isActive)
        #expect(!window.isVisible)
        updates.updater(updater, didAbortWithError: NSError(domain: "test", code: 1))
        #expect(!updates.installation.isPrepared)
        #expect(!feedback.isActive)
        #expect(window.isVisible)
    }

    @Test("快速退出取消延迟面板；重复进入不丢失需要恢复的窗口")
    func fastExitAndRepeatedPreparation() async throws {
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let feedback = ShutdownProgressController()
        feedback.begin(windows: [window], delay: .milliseconds(20))
        feedback.begin(windows: [], delay: .zero)
        feedback.finish(restoreWindows: true)
        try await Task.sleep(for: .milliseconds(50))
        #expect(window.isVisible)
        #expect(feedback.panel == nil)
        #expect(!feedback.isActive)
    }
}

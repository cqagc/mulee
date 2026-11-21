import AppKit

/// AppKit 安装窗口代理时注册通知；同一次安装期间，转发目标必须保持有效。
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    nonisolated(unsafe) let original: (any NSWindowDelegate)?
    weak var registration: MainWindowRegistrationView?
    private weak var appDelegate: AppDelegate?

    init(original: (any NSWindowDelegate)?, appDelegate: AppDelegate) {
        self.original = original
        self.appDelegate = appDelegate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard appDelegate?.windowShouldClose(sender) != false else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        // 原代理可能是持有窗口的控制器，关闭时解除注册视图对它的强引用。
        if let window = notification.object as? NSWindow, window.delegate === self {
            registration?.unregisterWindow()
        }
        original?.windowWillClose?(notification)
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

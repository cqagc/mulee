import AppKit

/// 保留 SwiftUI 原有窗口代理的生命周期回调，只拦截关闭判定。
final class MainWindowDelegate: NSObject, NSWindowDelegate {
    // ObjC 的查询与转发入口不隔离；弱引用仅在主线程安装，回调不执行 UI 操作。
    nonisolated(unsafe) weak var original: (any NSWindowDelegate)?
    weak var appDelegate: AppDelegate?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard appDelegate?.windowShouldClose(sender) != false else { return false }
        return original?.windowShouldClose?(sender) ?? true
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || original?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        original?.responds(to: selector) == true ? original : super.forwardingTarget(for: selector)
    }
}

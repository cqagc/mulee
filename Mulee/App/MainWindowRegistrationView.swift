import AppKit

final class MainWindowRegistrationView: NSView {
    private weak var appDelegate: AppDelegate?
    private weak var registeredWindow: NSWindow?
    private var closeDelegate: MainWindowDelegate?
    var interceptsClose = false

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if registeredWindow !== newWindow { unregisterWindow() }
        super.viewWillMove(toWindow: newWindow)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindow()
    }

    func registerWindow() {
        guard let window else { return }
        window.identifier = NSUserInterfaceItemIdentifier("mulee-main")
        guard interceptsClose, let appDelegate else {
            unregisterWindow()
            return
        }
        if let closeDelegate, window.delegate === closeDelegate { return }
        let previous = window.delegate
        // SwiftUI 可能先挂上新视图、再移除旧视图。新代理直接接管原目标。
        let original: (any NSWindowDelegate)?
        if let previous = previous as? MainWindowDelegate {
            original = previous.original
        } else {
            original = previous
        }
        let delegate = MainWindowDelegate(original: original, appDelegate: appDelegate)
        delegate.registration = self
        window.delegate = delegate
        registeredWindow = window
        closeDelegate = delegate
    }

    func unregisterWindow() {
        if let window = registeredWindow, let closeDelegate, window.delegate === closeDelegate {
            window.delegate = closeDelegate.original
        }
        registeredWindow = nil
        closeDelegate = nil
    }
}

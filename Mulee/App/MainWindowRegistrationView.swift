import AppKit

final class MainWindowRegistrationView: NSView {
    private let closeDelegate = MainWindowDelegate()

    init(appDelegate: AppDelegate) {
        closeDelegate.appDelegate = appDelegate
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerWindow()
    }

    func registerWindow() {
        window?.identifier = NSUserInterfaceItemIdentifier("mulee-main")
        if let window, window.delegate !== closeDelegate {
            closeDelegate.original = window.delegate
            window.delegate = closeDelegate
        }
    }
}

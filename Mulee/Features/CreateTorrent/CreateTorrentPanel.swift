import AppKit
import SwiftUI

final class CreateTorrentPanel: NSObject, NSWindowDelegate {
    private static var current: CreateTorrentPanel?
    private var window: NSWindow?
    private let model = CreateTorrentModel()

    static func show(model: AppModel) {
        if let window = current?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        guard let engine = model.bitTorrent?.engine else { return }
        let controller = CreateTorrentPanel()
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 568, height: 560),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = String(localized: "制作种子")
        window.isReleasedWhenClosed = false
        window.delegate = controller
        window.contentView = NSHostingView(rootView: CreateTorrentView(
            app: model, engine: engine, close: { [weak window] in window?.close() }, model: controller.model
        ))
        controller.window = window
        current = controller
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.cancel()
        window = nil
        Self.current = nil
    }
}

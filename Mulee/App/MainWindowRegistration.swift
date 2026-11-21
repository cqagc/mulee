import AppKit
import SwiftUI

struct MainWindowRegistration: NSViewRepresentable {
    let delegate: AppDelegate
    let interceptsClose: Bool

    func makeNSView(context: Context) -> MainWindowRegistrationView {
        MainWindowRegistrationView(appDelegate: delegate)
    }

    func updateNSView(_ view: MainWindowRegistrationView, context: Context) {
        view.interceptsClose = interceptsClose
        view.registerWindow()
    }

    static func dismantleNSView(_ view: MainWindowRegistrationView, coordinator: ()) {
        view.unregisterWindow()
    }
}

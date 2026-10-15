import AppKit
import SwiftUI

struct MainWindowRegistration: NSViewRepresentable {
    let delegate: AppDelegate

    func makeNSView(context: Context) -> MainWindowRegistrationView {
        MainWindowRegistrationView(appDelegate: delegate)
    }

    func updateNSView(_ view: MainWindowRegistrationView, context: Context) {
        view.registerWindow()
    }
}

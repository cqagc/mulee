import AppKit
import SwiftUI

/// 菜单栏常驻场景接收后台预填请求，即使主窗口已关闭也能重新打开。
struct MainWindowPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: model.mainWindowRequest, initial: true) { _, request in
            guard model.consumeMainWindowRequest(request) else { return }
            present()
        }
    }

    private func present() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "mulee-main" }) {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            window.attachedSheet?.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
    }
}

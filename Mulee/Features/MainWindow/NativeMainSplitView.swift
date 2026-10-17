import SwiftUI

struct NativeMainSplitView: NSViewControllerRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    let state: MainWindowState
    #if DEBUG
    var debugColorScheme: ColorScheme? = DebugLaunchOptions.colorScheme
    #endif

    func makeNSViewController(context: Context) -> MainSplitViewController {
        let controller = MainSplitViewController(state: state, model: model)
        for kind: MainWindowPane.Kind in [.sidebar, .tasks, .inspector] {
            let host = NSHostingController(rootView: MainWindowPane(kind: kind, state: state)
                .environment(model)
                .environment(settings))
            host.sizingOptions = []
            controller.addPane(host, kind: kind)
        }
        return controller
    }

    func updateNSViewController(_ controller: MainSplitViewController, context: Context) {
        #if DEBUG
        // 只有显式的截图参数才覆盖外观；普通启动必须继承窗口的玻璃与 vibrant 外观。
        controller.view.appearance = debugColorScheme.flatMap {
            NSAppearance(named: $0 == .dark ? .darkAqua : .aqua)
        }
        #else
        controller.view.appearance = nil
        #endif
        _ = state.isSidebarCollapsed
        _ = state.isInspectorCollapsed
        controller.synchronizeCollapseState()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: MainSplitViewController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 1240, height: 780))
    }
}

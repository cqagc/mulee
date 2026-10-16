import SwiftUI

struct NativeMainSplitView: NSViewControllerRepresentable {
    @Environment(AppModel.self) private var model
    @Environment(SettingsModel.self) private var settings
    @Environment(\.colorScheme) private var colorScheme
    let state: MainWindowState

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
        controller.view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        _ = state.isSidebarCollapsed
        _ = state.isInspectorCollapsed
        controller.synchronizeCollapseState()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: MainSplitViewController, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 1240, height: 780))
    }
}

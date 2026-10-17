import AppKit

final class MainSplitViewController: NSSplitViewController {
    let state: MainWindowState
    private let model: AppModel
    private var collapseObservations: [NSKeyValueObservation] = []
    private var didRestoreLayout = false
    private(set) var windowToolbar: MainWindowToolbar?

    init(state: MainWindowState, model: AppModel) {
        self.state = state
        self.model = model
        super.init(nibName: nil, bundle: nil)
        splitView = MainWindowDropView(state: state, model: model)
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.setAccessibilityIdentifier("main-split")
        minimumThicknessForInlineSidebars = 0
    }

    required init?(coder: NSCoder) { nil }

    func addPane(_ content: NSViewController, kind: MainWindowPane.Kind) {
        let controller: NSViewController
        if kind == .tasks {
            // 保护横幅属于内容区，不能随全尺寸内容视图进入工具栏毛玻璃后面。
            controller = NSViewController()
            controller.view = NSView()
            controller.addChild(content)
            content.view.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(content.view)
            NSLayoutConstraint.activate([
                content.view.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor),
                content.view.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
                content.view.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
                content.view.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor)
            ])
        } else {
            controller = content
        }
        let item: NSSplitViewItem
        switch kind {
        case .sidebar:
            item = NSSplitViewItem(sidebarWithViewController: controller)
            item.minimumThickness = 180
            item.maximumThickness = 300
            controller.view.frame.size = NSSize(width: state.sidebarWidth, height: 780)
            controller.view.setAccessibilityIdentifier("main-sidebar")
        case .tasks:
            item = NSSplitViewItem(viewController: controller)
            item.minimumThickness = 480
            item.holdingPriority = .defaultLow
            controller.view.setAccessibilityIdentifier("main-tasks")
        case .inspector:
            item = NSSplitViewItem(inspectorWithViewController: controller)
            item.minimumThickness = 270
            item.maximumThickness = 380
            controller.view.frame.size = NSSize(width: state.inspectorWidth, height: 780)
            controller.view.setAccessibilityIdentifier("main-inspector")
        }
        if kind != .tasks {
            // 高于列表的 250，低于 AppKit 分隔线拖动约束的 490。
            item.holdingPriority = NSLayoutConstraint.Priority(260)
            item.canCollapse = true
            item.canCollapseFromWindowResize = false
            item.collapseBehavior = .useConstraints
            item.preferredThicknessFraction = NSSplitViewItem.unspecifiedDimension
            collapseObservations.append(item.observe(\.isCollapsed, options: [.new]) { [weak self] _, change in
                let collapsed = change.newValue ?? false
                MainActor.assumeIsolated {
                    guard let self, self.didRestoreLayout else { return }
                    if kind == .sidebar {
                        self.state.isSidebarCollapsed = collapsed
                    } else {
                        self.state.isInspectorCollapsed = collapsed
                    }
                    self.windowToolbar?.refresh()
                }
            })
        }
        addSplitViewItem(item)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        installToolbar()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        installToolbar()
        restoreLayout()
    }

    func restoreLayout() {
        guard !didRestoreLayout, splitViewItems.count == 3,
              splitView.bounds.width >= Theme.mainWindowMinWidth else { return }
        let sidebarWidth = state.sidebarWidth
        let inspectorWidth = state.inspectorWidth
        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(sidebarWidth, ofDividerAt: 0)
        splitView.setPosition(splitView.bounds.width - inspectorWidth - splitView.dividerThickness, ofDividerAt: 1)
        splitViewItems[0].isCollapsed = state.isSidebarCollapsed
        splitViewItems[2].isCollapsed = state.isInspectorCollapsed
        didRestoreLayout = true
    }

    private func installToolbar() {
        guard let window = view.window else { return }
        window.styleMask.insert(.fullSizeContentView)
        window.toolbarStyle = .unified
        if windowToolbar == nil {
            windowToolbar = MainWindowToolbar(splitController: self, model: model, state: state)
        }
        if window.toolbar !== windowToolbar?.toolbar {
            window.toolbar = windowToolbar?.toolbar
            windowToolbar?.refresh()
        }
    }

    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard didRestoreLayout else { return }
        state.rememberWidths(
            sidebar: splitViewItems[0].isCollapsed ? nil : splitViewItems[0].viewController.view.frame.width,
            inspector: splitViewItems[2].isCollapsed ? nil : splitViewItems[2].viewController.view.frame.width
        )
    }

    func synchronizeCollapseState() {
        guard didRestoreLayout else { return }
        setCollapsed(state.isSidebarCollapsed, at: 0)
        setCollapsed(state.isInspectorCollapsed, at: 2)
    }

    private func setCollapsed(_ collapsed: Bool, at index: Int) {
        let item = splitViewItems[index]
        guard item.isCollapsed != collapsed else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            item.isCollapsed = collapsed
        } else {
            item.animator().isCollapsed = collapsed
        }
    }

    override func toggleSidebar(_ sender: Any?) {
        setCollapsed(!splitViewItems[0].isCollapsed, at: 0)
    }

    override func toggleInspector(_ sender: Any?) {
        setCollapsed(!splitViewItems[2].isCollapsed, at: 2)
    }
}

/// 在 AppKit 三栏的共同祖先接收拖放，不依赖 SwiftUI 跨 hosting controller 传递事件。
final class MainWindowDropView: NSSplitView {
    private let state: MainWindowState
    private let model: AppModel

    init(state: MainWindowState, model: AppModel) {
        self.state = state
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes(OpenURLDropHandler.pasteboardTypes)
    }

    required init?(coder: NSCoder) { nil }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let operation = dropOperation(for: sender.draggingPasteboard, allowed: sender.draggingSourceOperationMask)
        state.isDropTargeted = !operation.isEmpty
        return operation
    }

    func dropOperation(for pasteboard: NSPasteboard, allowed: NSDragOperation) -> NSDragOperation {
        guard OpenURLDropHandler.text(from: pasteboard) != nil else { return [] }
        // 浏览器可能只提供 link，Finder 通常提供 copy；两者都只预填草稿。
        if allowed.contains(.copy) { return .copy }
        if allowed.contains(.link) { return .link }
        if allowed.contains(.generic) { return .generic }
        return []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        state.isDropTargeted = false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
        state.isDropTargeted = false
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        OpenURLDropHandler.text(from: sender.draggingPasteboard) != nil
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        state.isDropTargeted = false
        return OpenURLDropHandler.accept(sender.draggingPasteboard, model: model)
    }
}

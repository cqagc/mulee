import AppKit
import Observation
import SwiftUI

/// 标识和视图在窗口生命周期内保持不变；状态变化只更新现有项目。
final class MainWindowToolbar: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
    static let sidebar = NSToolbarItem.Identifier("mulee.sidebar")
    static let newTask = NSToolbarItem.Identifier("mulee.newTask")
    static let toggleAll = NSToolbarItem.Identifier("mulee.toggleAll")
    static let slowMode = NSToolbarItem.Identifier("mulee.slowMode")
    static let speed = NSToolbarItem.Identifier("mulee.speed")
    static let search = NSToolbarItem.Identifier("mulee.search")
    static let inspector = NSToolbarItem.Identifier("mulee.inspector")
    // 与改版前一致：窗口标题在列表段最左，操作按钮靠右，搜索框位于详情栏上方。
    static let itemIdentifiers: [NSToolbarItem.Identifier] = [
        sidebar, .sidebarTrackingSeparator, .flexibleSpace, newTask, toggleAll, slowMode, speed, inspector,
        .inspectorTrackingSeparator, search,
    ]

    let toolbar = NSToolbar(identifier: "mulee.main.toolbar")
    private weak var splitController: MainSplitViewController?
    private let model: AppModel
    private let state: MainWindowState
    private var items: [NSToolbarItem.Identifier: NSToolbarItem] = [:]
    private let speedView = NSHostingView(rootView: TransferSpeedView(downloadRate: 0, uploadRate: 0))

    init(splitController: MainSplitViewController, model: AppModel, state: MainWindowState) {
        self.splitController = splitController
        self.model = model
        self.state = state
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        observeChanges()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if let item = items[identifier] { return item }
        let item: NSToolbarItem
        switch identifier {
        case .sidebarTrackingSeparator, .inspectorTrackingSeparator:
            guard let splitController else { return nil }
            item = NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: splitController.splitView,
                                                 dividerIndex: identifier == .sidebarTrackingSeparator ? 0 : 1)
        case Self.sidebar:
            item = button(identifier, title: state.sidebarToggleTitle, symbol: .sidebar, action: #selector(toggleSidebar))
        case Self.newTask:
            item = button(identifier, title: String(localized: "新建下载"), symbol: .add, action: #selector(showNewTask))
            item.toolTip = String(localized: "新建下载（⌘N）")
        case Self.toggleAll:
            item = button(identifier, title: String(localized: "全部暂停"), symbol: .pause, action: #selector(toggleTransfers))
        case Self.slowMode:
            item = button(identifier, title: String(localized: "慢速模式"), symbol: .slowMode, action: #selector(toggleSlowMode))
        case Self.speed:
            item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "传输速度")
            item.view = speedView
            // 固定宽度避免位数变化让搜索框和按钮移动。
            speedView.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                speedView.widthAnchor.constraint(equalToConstant: 180),
                speedView.heightAnchor.constraint(equalToConstant: 28),
            ])
        case Self.search:
            let searchItem = NSSearchToolbarItem(itemIdentifier: identifier)
            searchItem.label = String(localized: "搜索任务")
            searchItem.searchField.placeholderString = searchItem.label
            searchItem.searchField.setAccessibilityLabel(searchItem.label)
            searchItem.searchField.setAccessibilityIdentifier("main-search")
            searchItem.searchField.delegate = self
            searchItem.searchField.sendsSearchStringImmediately = true
            searchItem.searchField.stringValue = state.search
            searchItem.preferredWidthForSearchField = 180
            searchItem.searchField.widthAnchor.constraint(equalToConstant: 180).isActive = true
            item = searchItem
        case Self.inspector:
            item = button(identifier, title: String(localized: "详情栏"), symbol: .inspector, action: #selector(toggleInspector))
        default:
            return nil
        }
        // 导航项目会被 AppKit 移到系统标题之前，脱离分隔线和弹性空间的排列。
        item.visibilityPriority = .high
        items[identifier] = item
        refresh()
        return item
    }

    private func button(_ identifier: NSToolbarItem.Identifier, title: String, symbol: MuleeSymbol, action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = title
        item.toolTip = title
        item.image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: title)
        item.target = self
        item.action = action
        item.autovalidates = false
        return item
    }

    func refresh() {
        let canPause = model.tasks.contains { [.downloading, .waitingForSources, .seeding].contains($0.status) }
        let toggle = items[Self.toggleAll]
        toggle?.label = canPause ? String(localized: "全部暂停") : String(localized: "全部继续")
        toggle?.toolTip = String(localized: "全部暂停 / 继续")
        toggle?.image = NSImage(systemSymbolName: (canPause ? MuleeSymbol.pause : .resume).name,
                                accessibilityDescription: toggle?.label)
        toggle?.isEnabled = canPause || model.tasks.contains { $0.status == .paused }
        items[Self.slowMode]?.label = model.isSlowModeActive ? String(localized: "关闭慢速模式") : String(localized: "开启慢速模式")
        items[Self.slowMode]?.toolTip = model.slowModeReason ?? items[Self.slowMode]?.label
        items[Self.slowMode]?.image?.accessibilityDescription = items[Self.slowMode]?.label
        items[Self.slowMode]?.isBordered = model.isSlowModeActive
        items[Self.sidebar]?.toolTip = state.sidebarToggleTitle
        items[Self.sidebar]?.label = state.sidebarToggleTitle
        items[Self.inspector]?.toolTip = state.inspectorToggleTitle
        items[Self.inspector]?.image?.accessibilityDescription = state.inspectorToggleTitle
        speedView.rootView = TransferSpeedView(downloadRate: model.totalDownloadRate, uploadRate: model.totalUploadRate)
        let visible = state.visibleTasks(in: model)
        splitController?.view.window?.title = state.category.navigationTitle
        splitController?.view.window?.subtitle = SidebarItem.subtitle(for: visible)
        if let search = items[Self.search] as? NSSearchToolbarItem, search.searchField.stringValue != state.search {
            search.searchField.stringValue = state.search
        }
    }

    private func observeChanges() {
        withObservationTracking {
            refresh()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeChanges()
            }
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        state.search = field.stringValue
    }

    @objc private func toggleSidebar() {
        splitController?.toggleSidebar(nil)
    }

    @objc private func toggleInspector() {
        splitController?.toggleInspector(nil)
    }

    @objc private func showNewTask() {
        model.showNewTask()
    }

    @objc private func toggleSlowMode() {
        model.slowModeController?.toggle()
    }

    @objc private func toggleTransfers() {
        if model.tasks.contains(where: { [.downloading, .waitingForSources, .seeding].contains($0.status) }) {
            model.pauseAll()
        } else {
            model.resumeAll()
        }
    }
}

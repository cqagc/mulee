import AppKit
import MuleeCore
import SwiftUI
import Testing
@testable import Mulee

@Suite @MainActor struct MainWindowTests {
    @Test func restoresCollapseStateAndExpandedWidths() throws {
        let temporary = try TemporaryDefaults(prefix: "main-window.")
        defer { temporary.clean() }
        let state = MainWindowState(defaults: temporary.defaults)
        #expect(!state.isSidebarCollapsed)
        #expect(!state.isInspectorCollapsed)
        #expect(state.sidebarWidth == 220)
        #expect(state.inspectorWidth == 300)

        state.isSidebarCollapsed = true
        state.isInspectorCollapsed = true
        state.rememberWidths(sidebar: 248, inspector: 356)
        state.rememberWidths(sidebar: 0, inspector: .nan)

        let restored = MainWindowState(defaults: temporary.defaults)
        #expect(restored.isSidebarCollapsed)
        #expect(restored.isInspectorCollapsed)
        #expect(restored.sidebarWidth == 248)
        #expect(restored.inspectorWidth == 356)
        #expect(restored.sidebarToggleTitle == String(localized: "显示边栏"))
        #expect(restored.inspectorToggleTitle == String(localized: "显示详情栏"))
    }

    @Test func clampsStaleWidthsToDraggableRange() throws {
        let temporary = try TemporaryDefaults(prefix: "main-window.")
        defer { temporary.clean() }
        temporary.defaults.set(50, forKey: "mainWindow.sidebarWidth")
        temporary.defaults.set(900, forKey: "mainWindow.inspectorWidth")

        let state = MainWindowState(defaults: temporary.defaults)

        #expect(state.sidebarWidth == 180)
        #expect(state.inspectorWidth == 380)
    }

    @Test func filtersClearSelectionAfterSearchCategoryAndTaskChanges() throws {
        let temporary = try TemporaryDefaults(prefix: "main-window.")
        defer { temporary.clean() }
        let state = MainWindowState(defaults: temporary.defaults)
        let model = AppModel(preventsSleepWhileDownloading: false)
        model.selectedTaskID = MockData.longTailTask.id
        state.search = "雾港"
        state.clearHiddenSelection(in: model)
        #expect(model.selectedTaskID == MockData.longTailTask.id)

        state.selection = .http
        state.clearHiddenSelection(in: model)
        #expect(model.selectedTaskID == nil)
        #expect(state.visibleTasks(in: model).isEmpty)

        state.selection = nil
        state.search = ""
        model.selectedTaskID = MockData.longTailTask.id
        model.tasks.removeAll { $0.id == MockData.longTailTask.id }
        state.clearHiddenSelection(in: model)
        #expect(model.selectedTaskID == nil)
        #expect(state.category == .all)
    }

    @Test func nativeCollapseAndStateChangesStaySynchronized() throws {
        let temporary = try TemporaryDefaults(prefix: "main-window.")
        defer { temporary.clean() }
        let state = MainWindowState(defaults: temporary.defaults)
        let controller = makeController(state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 780)
        controller.view.layoutSubtreeIfNeeded()
        controller.restoreLayout()
        let sidebar = controller.splitViewItems[0]
        let list = controller.splitViewItems[1]
        let inspector = controller.splitViewItems[2]
        #expect(abs(sidebar.viewController.view.frame.width - 220) <= 1)
        #expect(abs(inspector.viewController.view.frame.width - 300) <= 1)
        #expect(sidebar.behavior == .sidebar)
        #expect(inspector.behavior == .inspector)
        #expect(sidebar.holdingPriority > list.holdingPriority)
        #expect(inspector.holdingPriority > list.holdingPriority)
        #expect(sidebar.holdingPriority.rawValue < 490)
        #expect(!sidebar.canCollapseFromWindowResize)
        #expect(inspector.maximumThickness == 380)
        #expect(Theme.mainWindowMinWidth >= sidebar.maximumThickness + list.minimumThickness + inspector.maximumThickness + 2)

        sidebar.isCollapsed = true
        inspector.isCollapsed = true
        #expect(state.isSidebarCollapsed)
        #expect(state.isInspectorCollapsed)

        state.isSidebarCollapsed = false
        state.isInspectorCollapsed = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            controller.synchronizeCollapseState()
        }
        #expect(!sidebar.isCollapsed)
        #expect(!inspector.isCollapsed)
    }

    @Test func toolbarRefreshRetainsItemsSearchAndTrackingSeparators() throws {
        let temporary = try TemporaryDefaults(prefix: "main-window.")
        defer { temporary.clean() }
        let state = MainWindowState(defaults: temporary.defaults)
        let model = AppModel(preventsSleepWhileDownloading: false)
        let controller = makeController(state: state, model: model)
        let chrome = MainWindowToolbar(splitController: controller, model: model, state: state)
        let identifiers = chrome.toolbarDefaultItemIdentifiers(chrome.toolbar)
        #expect(identifiers == [
            MainWindowToolbar.sidebar, .sidebarTrackingSeparator, .flexibleSpace,
            MainWindowToolbar.newTask, MainWindowToolbar.toggleAll, MainWindowToolbar.slowMode, MainWindowToolbar.speed,
            MainWindowToolbar.inspector, .inspectorTrackingSeparator, MainWindowToolbar.search,
        ])
        var items: [NSToolbarItem] = []
        for identifier in identifiers where identifier != .flexibleSpace {
            items.append(try #require(chrome.toolbar(chrome.toolbar, itemForItemIdentifier: identifier, willBeInsertedIntoToolbar: true)))
        }
        let separators = items.compactMap { $0 as? NSTrackingSeparatorToolbarItem }
        #expect(separators.map(\.dividerIndex) == [0, 1])
        #expect(items.allSatisfy { !$0.isNavigational })
        #expect(separators.allSatisfy { $0.splitView === controller.splitView })
        let search = try #require(items.first { $0.itemIdentifier == MainWindowToolbar.search } as? NSSearchToolbarItem)
        #expect(search.preferredWidthForSearchField == 180)
        search.searchField.stringValue = "Ubuntu"
        chrome.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search.searchField))
        #expect(state.search == "Ubuntu")

        state.isInspectorCollapsed = true
        state.isSidebarCollapsed = true
        chrome.refresh()
        for item in items {
            #expect(chrome.toolbar(chrome.toolbar, itemForItemIdentifier: item.itemIdentifier, willBeInsertedIntoToolbar: true) === item)
        }
        #expect(chrome.toolbarDefaultItemIdentifiers(chrome.toolbar) == identifiers)
        #expect(items.first { $0.itemIdentifier == MainWindowToolbar.inspector }?.toolTip == String(localized: "显示详情栏"))
        #expect(search.searchField.stringValue == "Ubuntu")
    }

    private func makeController(state: MainWindowState, model: AppModel? = nil) -> MainSplitViewController {
        let controller = MainSplitViewController(state: state, model: model ?? AppModel(preventsSleepWhileDownloading: false))
        for kind: MainWindowPane.Kind in [.sidebar, .tasks, .inspector] {
            controller.addPane(NSHostingController(rootView: Color.clear), kind: kind)
        }
        return controller
    }
}

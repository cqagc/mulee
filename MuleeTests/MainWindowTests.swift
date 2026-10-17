import AppKit
import MuleeCore
import SwiftUI
import Testing
@testable import Mulee

@Suite @MainActor struct MainWindowTests {
    @Test func sidebarScrollerDiagnostics() async throws {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        for minimal in [true, false] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                for usesMaterial in [false, true] {
                    let content: AnyView
                    if minimal {
                        content = AnyView(List(0..<50, id: \.self) { Text("Item \($0)") }.listStyle(.sidebar))
                    } else {
                        content = AnyView(MainSidebarView(selection: .constant(.all)).environment(model))
                    }
                    let host = NSHostingController(rootView: content)
                    host.sizingOptions = []
                    let split = NSSplitViewController()
                    split.splitView.isVertical = true
                    let container: NSViewController
                    if usesMaterial {
                        let sidebar = MainSidebarContainerViewController(content: host)
                        sidebar.applyScrollerStyle(.legacy)
                        container = sidebar
                    } else {
                        container = host
                    }
                    split.addSplitViewItem(NSSplitViewItem(sidebarWithViewController: container))
                    split.addSplitViewItem(NSSplitViewItem(viewController: NSViewController()))
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
                                          styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                    window.contentViewController = split
                    defer { window.contentViewController = nil }
                    split.view.appearance = NSAppearance(named: appearance)
                    split.view.layoutSubtreeIfNeeded()
                    await Task.yield()
                    split.view.layoutSubtreeIfNeeded()
                    let scroll = try #require(sidebarDescendants(host.view).compactMap { $0 as? NSScrollView }.first)
                    // 仅测试传统滚动条，不改用户偏好或产品中的滚动条策略。
                    scroll.scrollerStyle = .legacy
                    scroll.tile()
                    let effects = sidebarAncestors(scroll).compactMap { $0 as? NSVisualEffectView }
                    #expect(effects.contains { $0.material == .sidebar } == usesMaterial)
                    #expect(!scroll.drawsBackground)
                    #expect(scroll.verticalScroller != nil)
                    #expect(scroll.bounds.width > 0 && scroll.bounds.height > 0)
                    print("SCROLLER minimal=\(minimal) appearance=\(appearance.rawValue) material=\(usesMaterial) \(sidebarDescription(scroll))")
                }
            }
        }
    }

    @Test func sidebarMaterialTracksSystemStyleWithoutRecreatingContent() throws {
        let temporary = try TemporaryDefaults(prefix: "sidebar-style.")
        defer { temporary.clean() }
        let controller = makeController(state: MainWindowState(defaults: temporary.defaults))
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 780)
        let sidebar = try #require(controller.splitViewItems[0].viewController as? MainSidebarContainerViewController)
        let content = sidebar.content
        let preferred = NSScroller.preferredScrollerStyle
        for style: NSScroller.Style in [.legacy, .overlay, .legacy, .overlay] {
            sidebar.applyScrollerStyle(style)
            controller.view.layoutSubtreeIfNeeded()
            #expect(sidebar.children.count == 1)
            #expect(sidebar.content === content)
            #expect(content.view.frame.size == sidebar.view.bounds.size)
            #expect(NSScroller.preferredScrollerStyle == preferred)
            if style == .legacy {
                let effect = try #require(sidebar.materialView)
                #expect(effect.material == .sidebar)
                #expect(effect.blendingMode == .withinWindow)
                #expect(effect.state == .followsWindowActiveState)
                #expect(content.view.superview === effect)
                sidebar.applyScrollerStyle(style)
                #expect(sidebar.materialView === effect)
            } else {
                #expect(sidebar.materialView == nil)
                #expect(content.view.superview === sidebar.view)
                #expect(sidebar.view.subviews.count == 1)
            }
        }
        NotificationCenter.default.post(name: NSScroller.preferredScrollerStyleDidChangeNotification, object: nil)
        #expect((sidebar.materialView != nil) == (preferred == .legacy))
    }

    @Test func sidebarMaterialPreservesHighContrastAppearanceWithoutAList() async throws {
        let host = NSViewController()
        host.view = NSView()
        let sidebar = MainSidebarContainerViewController(content: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 560),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = sidebar
        defer { window.contentViewController = nil }
        for appearance in [NSAppearance.Name.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua] {
            window.appearance = try #require(NSAppearance(named: appearance))
            for style: NSScroller.Style in [.legacy, .overlay] {
                sidebar.applyScrollerStyle(style)
                sidebar.view.layoutSubtreeIfNeeded()
                await Task.yield()
                sidebar.view.layoutSubtreeIfNeeded()
                #expect(host.view.isDescendant(of: sidebar.view))
                let parent = try #require(host.view.superview)
                #expect(sidebar.view.appearance == nil)
                #expect(parent.appearance == nil)
                #expect(host.view.effectiveAppearance.name == parent.effectiveAppearance.name)
                #expect(host.view.frame.size == sidebar.view.bounds.size)
            }
        }
    }

    private func sidebarDescendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(sidebarDescendants)
    }

    private func sidebarDescription(_ scroll: NSScrollView) -> String {
        let chain = sidebarAncestors(scroll).map { view in
            var details = "\(type(of: view)){appearance=\(view.effectiveAppearance.name.rawValue),opaque=\(view.isOpaque),vibrant=\(view.allowsVibrancy)"
            if let effect = view as? NSVisualEffectView {
                details += ",material=\(effect.material.rawValue),blend=\(effect.blendingMode.rawValue)"
            }
            return details + "}"
        }
        let scroller = scroll.verticalScroller
        return "style=\(scroll.scrollerStyle.rawValue) knob=\(scroller?.knobStyle.rawValue ?? -1) scrollerAppearance=\(scroller?.effectiveAppearance.name.rawValue ?? "nil") drawsBackground=\(scroll.drawsBackground) chain=\(chain.joined(separator: " -> "))"
    }

    private func sidebarAncestors(_ view: NSView) -> [NSView] {
        var chain: [NSView] = []
        var ancestor: NSView? = view
        while let current = ancestor {
            chain.append(current)
            ancestor = current.superview
        }
        return chain
    }

    @Test func escapeClosesNewTaskWhileMultilineEditorHasFocus() async throws {
        let temporary = try TemporaryDefaults(prefix: "new-task-escape.")
        defer { temporary.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        model.isShowingNewTask = true
        let draft = NewTaskModel(inputText: "https://example.org/example.bin", saveDirectory: URL(filePath: "/tmp"))
        let host = NSHostingController(rootView: NewTaskSheet(draft: draft)
            .environment(model).environment(SettingsModel(defaults: temporary.defaults)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentViewController = host
        defer { window.contentViewController = nil }
        host.view.layoutSubtreeIfNeeded()
        await Task.yield()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let field = try #require(descendants(host.view).compactMap { $0 as? NSTextField }.first {
            $0.isEditable && $0.stringValue == draft.inputText
        })
        #expect(window.makeFirstResponder(field))
        let editor = try #require(window.fieldEditor(true, for: field) as? NSTextView)
        #expect(window.makeFirstResponder(editor))
        #expect(editor.string == draft.inputText)
        let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                 windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                                                 charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        window.sendEvent(escape)
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while model.isShowingNewTask, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!model.isShowingNewTask)
    }

    @Test func taskContentStaysBelowUnifiedToolbar() throws {
        let temporary = try TemporaryDefaults(prefix: "window-safe-area.")
        defer { temporary.clean() }
        let controller = makeController(state: MainWindowState(defaults: temporary.defaults))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 780),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        controller.viewDidAppear()
        controller.view.layoutSubtreeIfNeeded()
        defer { window.contentViewController = nil }
        let pane = controller.splitViewItems[1].viewController
        let content = try #require(pane.children.first)
        let frame = content.view.convert(content.view.bounds, to: nil)
        #expect(frame.maxY <= window.contentLayoutRect.maxY + 1)
        #expect(frame.height > 0)
    }

    @Test func menuPanelRecreationDoesNotReplayWindowRequest() {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        #expect(!model.consumeMainWindowRequest(0))
        model.mainWindowRequest += 1
        #expect(model.consumeMainWindowRequest(model.mainWindowRequest))
        // 面板和标签重建都会重新执行 initial 回调，但不能再次呈现窗口。
        #expect(!model.consumeMainWindowRequest(model.mainWindowRequest))
        #expect(!model.consumeMainWindowRequest(model.mainWindowRequest))
        model.mainWindowRequest += 1
        #expect(model.consumeMainWindowRequest(model.mainWindowRequest))
    }

    @Test func activationDoesNotRequestWindowButDockReopenDoes() throws {
        let temporary = try TemporaryDefaults(prefix: "window-activation.")
        defer { temporary.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let delegate = AppDelegate()
        delegate.configure(model: model, settings: SettingsModel(defaults: temporary.defaults), usesSampleData: true)
        defer { delegate.openURLRouter?.stopCookieCleanup() }
        let entry: any NSApplicationDelegate = delegate
        entry.applicationDidBecomeActive?(Notification(name: NSApplication.didBecomeActiveNotification))
        #expect(model.mainWindowRequest == 0)
        #expect(!delegate.applicationShouldHandleReopen(NSApplication.shared, hasVisibleWindows: true))
        #expect(model.mainWindowRequest == 1)
    }

    @Test func nativeSplitViewRegistersDropsAboveAllThreePanes() throws {
        let temporary = try TemporaryDefaults(prefix: "window-drop.")
        defer { temporary.clean() }
        let state = MainWindowState(defaults: temporary.defaults)
        let controller = makeController(state: state)
        controller.view.frame = NSRect(x: 0, y: 0, width: 1240, height: 780)
        controller.view.layoutSubtreeIfNeeded()
        let receiver = try #require(controller.splitView as? MainWindowDropView)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("https://example.com/download.zip", forType: .string)
        #expect(receiver.dropOperation(for: pasteboard, allowed: .copy) == .copy)
        #expect(receiver.dropOperation(for: pasteboard, allowed: .link) == .link)
        #expect(receiver.dropOperation(for: pasteboard, allowed: .move).isEmpty)
        #expect(Set(controller.splitView.registeredDraggedTypes).isSuperset(of: OpenURLDropHandler.pasteboardTypes))
        #expect(controller.splitViewItems.count == 3)
        for item in controller.splitViewItems {
            #expect(item.viewController.view.isDescendant(of: controller.splitView))
        }
    }

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

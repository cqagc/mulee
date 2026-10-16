import Foundation
import MuleeCore
import Observation

/// 三个 hosting controller 和原生工具栏共享的窗口状态。
@MainActor
@Observable
final class MainWindowState {
    var selection: SidebarItem? = .all
    var search = ""
    var isSidebarCollapsed: Bool {
        didSet { defaults.set(isSidebarCollapsed, forKey: "mainWindow.sidebarCollapsed") }
    }
    var isInspectorCollapsed: Bool {
        didSet { defaults.set(isInspectorCollapsed, forKey: "mainWindow.inspectorCollapsed") }
    }
    private(set) var sidebarWidth: Double
    private(set) var inspectorWidth: Double
    @ObservationIgnored private let defaults: UserDefaults

    var category: SidebarItem { selection ?? .all }
    var inspectorToggleTitle: String {
        isInspectorCollapsed ? String(localized: "显示详情栏") : String(localized: "隐藏详情栏")
    }
    var sidebarToggleTitle: String {
        isSidebarCollapsed ? String(localized: "显示边栏") : String(localized: "隐藏边栏")
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isSidebarCollapsed = defaults.bool(forKey: "mainWindow.sidebarCollapsed")
        isInspectorCollapsed = defaults.bool(forKey: "mainWindow.inspectorCollapsed")
        sidebarWidth = Self.restoredWidth(defaults, key: "mainWindow.sidebarWidth", fallback: Theme.sidebarWidth, range: 180...300)
        inspectorWidth = Self.restoredWidth(defaults, key: "mainWindow.inspectorWidth", fallback: Theme.inspectorWidth, range: 270...380)
    }

    func visibleTasks(in model: AppModel) -> [DownloadTask] {
        category.filter(model.tasks, search: search)
    }

    func clearHiddenSelection(in model: AppModel) {
        if let id = model.selectedTaskID, !visibleTasks(in: model).contains(where: { $0.id == id }) {
            model.selectedTaskID = nil
        }
    }

    func rememberWidths(sidebar: Double?, inspector: Double?) {
        if let sidebar, sidebar.isFinite, (180...300).contains(sidebar), sidebar != sidebarWidth {
            sidebarWidth = sidebar
            defaults.set(sidebar, forKey: "mainWindow.sidebarWidth")
        }
        if let inspector, inspector.isFinite, (270...380).contains(inspector), inspector != inspectorWidth {
            inspectorWidth = inspector
            defaults.set(inspector, forKey: "mainWindow.inspectorWidth")
        }
    }

    private static func restoredWidth(_ defaults: UserDefaults, key: String, fallback: Double, range: ClosedRange<Double>) -> Double {
        guard let width = defaults.object(forKey: key) as? Double, width.isFinite else { return fallback }
        return min(range.upperBound, max(range.lowerBound, width))
    }
}

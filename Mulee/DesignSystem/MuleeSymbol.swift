/// App 内使用的全部 SF Symbols。规范见 Design/ICONS.md。
/// 视图里不准直接写符号名字符串，一律通过这个枚举引用。
enum MuleeSymbol: String, CaseIterable {
    // 侧边栏 · 按状态
    case all = "tray.full"
    case downloading = "arrow.down.circle"
    case waitingForSources = "hourglass"
    case seeding = "arrow.up.circle"
    case completed = "checkmark.circle"

    // 任务类型
    case http = "globe"
    case bittorrent = "point.3.connected.trianglepath.dotted"
    case ed2k = "antenna.radiowaves.left.and.right"
    case video = "play.rectangle"

    // 任务状态
    case statusDownloading = "arrow.down"
    case statusSeeding = "arrow.up"
    case statusExtracting = "archivebox"
    case statusMerging = "film.stack"
    case statusPaused = "pause.circle"
    case statusCompleted = "checkmark.circle.fill"
    case statusFailed = "exclamationmark.triangle.fill"

    // 工具栏与操作
    case add = "plus"
    case pause = "pause.fill"
    case resume = "play.fill"
    case search = "magnifyingglass"
    case copy = "doc.on.doc"
    case revealInFinder = "folder"
    case delete = "trash"
    case retry = "arrow.clockwise"
    case inspector = "sidebar.right"

    // 网络
    case statusDot = "circle.fill"
    case proxyWarning = "exclamationmark.shield.fill"
    case network = "network"

    // 设置
    case settingsGeneral = "gearshape"

    // 解压规则
    case ruleSourceSite = "link"
    case ruleFilenamePrefix = "textformat"
    case ruleFilenameRegex = "chevron.left.forwardslash.chevron.right"
    case rulePasswordBook = "key"

    // 菜单栏
    case preventSleep = "cup.and.heat.waves"

    /// SF Symbol 名称，传给 `Image(systemName:)` / `Label(_:systemImage:)`。
    var name: String { rawValue }
}

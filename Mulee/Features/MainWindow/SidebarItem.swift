import MuleeCore

/// 主窗口分类；筛选不依赖界面状态，便于独立验证。
enum SidebarItem: String, CaseIterable, Identifiable {
    case all, downloading, waitingForSources, seeding, completed
    case http, bittorrent, ed2k, video

    var id: Self { self }

    static let downloads: [Self] = [.all, .downloading, .waitingForSources, .seeding, .completed]
    static let kinds: [Self] = [.http, .bittorrent, .ed2k, .video]

    var title: String {
        switch self {
        case .all: "全部"
        case .downloading: "下载中"
        case .waitingForSources: "等待来源"
        case .seeding: "做种中"
        case .completed: "已完成"
        case .http: "网页 HTTP"
        case .bittorrent: "BT / 磁力"
        case .ed2k: "电驴 ed2k"
        case .video: "视频"
        }
    }

    var navigationTitle: String { self == .all ? "全部任务" : title }

    var symbol: MuleeSymbol {
        switch self {
        case .all: .all
        case .downloading: .downloading
        case .waitingForSources: .waitingForSources
        case .seeding: .seeding
        case .completed: .completed
        case .http: .http
        case .bittorrent: .bittorrent
        case .ed2k: .ed2k
        case .video: .video
        }
    }

    func includes(_ task: DownloadTask) -> Bool {
        switch self {
        case .all: true
        case .downloading: [.downloading, .postProcessing, .extracting].contains(task.status)
        case .waitingForSources: task.status == .waitingForSources
        case .seeding: task.status == .seeding
        case .completed: task.status == .completed
        case .http: task.kind == .http
        case .bittorrent: task.kind == .bittorrent
        case .ed2k: task.kind == .ed2k
        case .video: task.kind == .video
        }
    }

    func filter(_ tasks: [DownloadTask], search: String = "") -> [DownloadTask] {
        tasks.filter { includes($0) && (search.isEmpty || $0.name.localizedStandardContains(search)) }
    }

    static func subtitle(for tasks: [DownloadTask]) -> String {
        "\(tasks.count.formatted()) 个任务 · \(downloading.filter(tasks).count.formatted()) 个进行中"
    }
}

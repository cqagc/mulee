import Foundation

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
        case .all: String(localized: "全部")
        case .downloading: String(localized: "下载中")
        case .waitingForSources: String(localized: "等待来源")
        case .seeding: String(localized: "做种中")
        case .completed: String(localized: "已完成")
        case .http: String(localized: "网页 HTTP")
        case .bittorrent: String(localized: "BT / 磁力")
        case .ed2k: String(localized: "电驴 ed2k")
        case .video: String(localized: "视频")
        }
    }

    var navigationTitle: String { self == .all ? String(localized: "全部任务") : title }

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
        if self == .all, search.isEmpty { return tasks }
        return tasks.filter { includes($0) && (search.isEmpty || $0.name.localizedStandardContains(search)) }
    }

    /// 一次遍历完成侧边栏计数，避免为每个分类分配过滤后的任务数组。
    static func counts(in tasks: [DownloadTask]) -> [Self: Int] {
        var counts: [Self: Int] = [.all: tasks.count]
        for task in tasks {
            switch task.status {
            case .downloading, .extracting, .postProcessing: counts[.downloading, default: 0] += 1
            case .waitingForSources: counts[.waitingForSources, default: 0] += 1
            case .seeding: counts[.seeding, default: 0] += 1
            case .completed: counts[.completed, default: 0] += 1
            default: break
            }
        }
        return counts
    }

    static func subtitle(for tasks: [DownloadTask]) -> String {
        let activeCount = tasks.count { downloading.includes($0) }
        return String(localized: "\(tasks.count) 个任务 · \(activeCount) 个进行中")
    }
}

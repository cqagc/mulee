import Foundation

import MuleeCore

/// 主窗口分类；筛选不依赖界面状态，便于独立验证。
enum SidebarItem: Hashable, Identifiable {
    case all, downloading, waitingForSources, seeding, completed
    case http, bittorrent, ed2k, video
    case stalled, failed, completedToday, tagged, recentlyDeleted
    case tag(String)

    static let allCases: [Self] = downloads + kinds + smartLists + [.recentlyDeleted]
    static let smartLists: [Self] = [.stalled, .failed, .completedToday, .tagged]

    var id: Self { self }

    static let downloads: [Self] = [.all, .downloading, .waitingForSources, .seeding, .completed]
    static let kinds: [Self] = [.http, .bittorrent, .ed2k, .video]

    var title: String {
        switch self {
        case .stalled: String(localized: "卡住超过 1 小时")
        case .failed: String(localized: "出错")
        case .completedToday: String(localized: "今天完成")
        case .tagged: String(localized: "按标签")
        case .recentlyDeleted: String(localized: "最近删除")
        case .tag(let name): name
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
        case .stalled: .waitingForSources
        case .failed: .statusFailed
        case .completedToday: .completed
        case .tagged, .tag: .tags
        case .recentlyDeleted: .delete
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

    func includes(_ task: DownloadTask, now: Date = .now, calendar: Calendar = .current) -> Bool {
        if self == .recentlyDeleted { return task.deletedAt != nil }
        guard task.deletedAt == nil else { return false }
        return switch self {
        case .stalled:
            task.status == .downloading && task.lastProgressAt.map { now.timeIntervalSince($0) >= 3600 } == true
        case .failed: task.status == .failed
        case .completedToday: task.completedAt.map { calendar.isDate($0, inSameDayAs: now) } == true
        case .tagged: !(task.tags ?? []).isEmpty
        case .tag(let name): task.tags?.contains(name) == true
        case .recentlyDeleted: false
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
        let now = Date.now
        let calendar = Calendar.current
        return tasks.filter { includes($0, now: now, calendar: calendar) && (search.isEmpty || $0.name.localizedStandardContains(search)) }
    }

    /// 一次遍历完成侧边栏计数，避免为每个分类分配过滤后的任务数组。
    static func counts(in tasks: [DownloadTask]) -> [Self: Int] {
        var counts: [Self: Int] = [.all: 0]
        let now = Date.now
        let calendar = Calendar.current
        for task in tasks {
            if task.deletedAt != nil {
                counts[.recentlyDeleted, default: 0] += 1
                continue
            }
            counts[.all, default: 0] += 1
            switch task.status {
            case .downloading, .extracting, .postProcessing: counts[.downloading, default: 0] += 1
            case .waitingForSources: counts[.waitingForSources, default: 0] += 1
            case .seeding: counts[.seeding, default: 0] += 1
            case .completed: counts[.completed, default: 0] += 1
            default: break
            }
            if stalled.includes(task, now: now, calendar: calendar) { counts[.stalled, default: 0] += 1 }
            if task.status == .failed { counts[.failed, default: 0] += 1 }
            if task.completedAt.map({ calendar.isDate($0, inSameDayAs: now) }) == true {
                counts[.completedToday, default: 0] += 1
            }
            if !(task.tags ?? []).isEmpty { counts[.tagged, default: 0] += 1 }
            for tag in Set(task.tags ?? []) { counts[.tag(tag), default: 0] += 1 }
        }
        return counts
    }

    static func subtitle(for tasks: [DownloadTask]) -> String {
        let counts = counts(in: tasks)
        return String(localized: "\(counts[.all, default: 0]) 个任务 · \(counts[.downloading, default: 0]) 个进行中")
    }
}

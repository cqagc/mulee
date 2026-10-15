import Foundation
import MuleeCore

/// 任务展示文案的唯一入口。日期依赖可注入，测试不受系统时间影响。
struct TaskPresentation {
    let task: DownloadTask
    let now: Date
    let calendar: Calendar

    init(task: DownloadTask, now: Date = .now, calendar: Calendar = .current) {
        self.task = task
        self.now = now
        self.calendar = calendar
    }

    var typeLabel: String {
        switch task.kind {
        case .http: "HTTP"
        case .bittorrent: "BT"
        case .ed2k: "ED2K"
        case .video: "视频"
        }
    }

    var size: String { task.totalBytes.map(Self.bytes) ?? "大小未知" }

    var metadata: String {
        if task.status == .extracting, let rule = task.postDownload.matchedRuleName {
            return "\(size) · 命中解压规则「\(rule)」"
        }
        switch task.detail {
        case .http(let connections):
            // 只有正在下载时连接数才有意义；排队、暂停、完成时只显示大小。
            guard task.status == .downloading, connections > 0 else { return size }
            return "\(size) · \(connections.formatted()) 线程"
        case .bittorrent(let files, let selected, let peers, let ratio):
            if task.status == .seeding {
                return "\(size) · 分享率 \(ratio.formatted(.number.precision(.fractionLength(2)))) / 1.00"
            }
            return "\(files.formatted()) 个文件，已选 \(selected.formatted()) 个 · \(peers.formatted()) 个节点"
        case .ed2k(_, let info):
            if info.sourceCount > 0 {
                let queue = info.queueRank.map { "，排队第 \($0.formatted()) 位" } ?? ""
                return "\(size) · \(info.sourceCount.formatted()) 个来源\(queue)"
            }
            let lastSeen = info.lastCompleteSourceSeen.map { "，完整源最后出现于 \(monthDay($0))" } ?? "，尚未见到完整源"
            return "\(size) · 暂无来源\(lastSeen)"
        case .video(let site, let quality, let danmaku):
            return "\(site.displayName) · \(quality)\(danmaku ? " · 弹幕转 ASS" : "")"
        }
    }

    var progress: Double {
        switch task.status {
        case .extracting:
            Self.clamped(task.postDownload.extractProgress ?? 0)
        case .seeding:
            if case .bittorrent(_, _, _, let ratio) = task.detail { Self.clamped(ratio) } else { 0 }
        case .completed:
            1
        default:
            Self.clamped(task.fractionCompleted ?? 0)
        }
    }

    var progressStyle: TaskProgressStyle {
        switch task.status {
        case .waitingForSources, .failed: .waiting
        case .extracting, .seeding: .success
        case .completed: .completed
        default: .accent
        }
    }

    var progressText: String {
        switch task.status {
        case .extracting: "解压中 · \(percent)"
        case .seeding: "做种 \(percent) · 到 1:1 后降速"
        case .postProcessing: "\(percent) · 合并音视频"
        case .completed: size
        default: "\(percent) · \(receivedAndTotal)"
        }
    }

    var inspectorProgressText: String {
        guard task.kind == .ed2k, let total = task.totalBytes else { return progressText }
        return "\(percent) · 已收到 \(Self.bytes(task.receivedBytes))，剩余 \(Self.bytes(max(0, total - task.receivedBytes)))"
    }

    var statusTitle: String {
        switch task.status {
        case .downloading: Self.rate(task.downloadRate)
        case .waitingForSources: "等待来源"
        case .postProcessing: "处理中"
        case .extracting: "解压中"
        case .seeding: "↑ \(Self.rate(task.uploadRate))"
        case .completed: "已完成"
        case .paused: "已暂停"
        case .failed: "需要处理"
        case .queued: "排队中"
        case .engineUnavailable: "引擎未接入"
        }
    }

    var statusSubtitle: String {
        switch task.status {
        case .downloading: task.estimatedTimeRemaining.map { "剩 \(Self.duration($0, remaining: true))" } ?? "正在下载"
        case .waitingForSources: longTail.map { "已挂 \(days(since: $0.waitingSince)) 天" } ?? "耐心等待"
        case .postProcessing: "即将完成"
        case .extracting: task.postDownload.filenameEncoding == nil ? "正在解压文件" : "已修复文件名编码"
        case .seeding: "做种中"
        case .completed: task.completedAt.map(time) ?? ""
        case .paused: ""
        case .failed: task.errorMessage ?? "可稍后重试"
        case .queued: "等待空位"
        case .engineUnavailable: "暂时只记录链接"
        }
    }

    var statusSymbol: MuleeSymbol {
        switch task.status {
        case .downloading: .statusDownloading
        case .waitingForSources: .waitingForSources
        case .postProcessing: .statusMerging
        case .extracting: .statusExtracting
        case .seeding: .statusSeeding
        case .completed: .statusCompleted
        case .paused, .engineUnavailable: .statusPaused
        case .failed: .statusFailed
        case .queued: .waitingForSources
        }
    }

    var isStatusEmphasized: Bool { [.waitingForSources, .completed, .failed].contains(task.status) }
    var canPauseOrResume: Bool { [.downloading, .waitingForSources, .queued, .paused].contains(task.status) }
    var pauseTitle: String { task.status == .paused ? "继续" : "暂停" }
    var pauseSymbol: MuleeSymbol { task.status == .paused ? .resume : .pause }

    var longTail: LongTailInfo? {
        if case .ed2k(_, let info) = task.detail { info } else { nil }
    }

    var longTailStatus: String {
        guard task.status == .waitingForSources || task.status == .downloading else { return statusTitle }
        return longTail?.queueRank.map { "排队中，第 \($0.formatted()) 位" } ?? "等待来源"
    }

    var sourceSummary: String {
        guard let info = longTail else { return "" }
        return "\(info.sourceCount.formatted()) 个（\(info.completeSourceCount.formatted()) 个完整）"
    }

    var lastCompleteSource: String {
        guard let date = longTail?.lastCompleteSourceSeen else { return "尚未见到" }
        let count = days(since: date)
        return count == "0" ? "今天" : "\(count) 天前"
    }

    var waitingDuration: String { longTail.map { "\(days(since: $0.waitingSince)) 天" } ?? "" }
    var transferDuration: String { longTail.map { Self.duration($0.activeTransferDuration) } ?? "" }
    var extractionSetting: String { task.postDownload.autoExtract ? "开" : "关" }
    var filenameEncoding: String { task.postDownload.filenameEncoding.map { "自动检测（\($0)）" } ?? "自动检测" }

    var hash: String? {
        if case .ed2k(let hash, _) = task.detail { "ED2K \(hash)" } else { nil }
    }

    /// 文件大小与访达一致，按十进制换算（.file）。
    static func bytes(_ value: Int64) -> String {
        let style = ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false,
                                         includesActualByteCount: false, locale: Locale(identifier: "en_US"))
        return max(0, value).formatted(style)
            .replacing("kB", with: "KB")
    }

    static func rate(_ value: Int64) -> String {
        if value <= 0 {
            return "\(0.formatted()) KB/s"
        }
        return "\(bytes(value))/s"
    }

    private var percent: String {
        progress.formatted(.percent.precision(.fractionLength(0)).locale(Locale(identifier: "en_US")))
    }

    private var receivedAndTotal: String {
        guard let total = task.totalBytes, total > 0 else { return "已收到 \(Self.bytes(task.receivedBytes))" }
        let units: ByteCountFormatStyle.Units = total >= 1_000_000_000 ? .gb : total >= 1_000_000 ? .mb : .kb
        let style = ByteCountFormatStyle(style: .file, allowedUnits: units, spellsOutZero: false, includesActualByteCount: false, locale: Locale(identifier: "en_US"))
        let received = max(0, task.receivedBytes).formatted(style)
        let number = received.split(separator: " ").first.map(String.init) ?? received
        return "\(number) / \(total.formatted(style))"
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private func days(since date: Date) -> String {
        max(0, calendar.dateComponents([.day], from: date, to: now).day ?? 0).formatted()
    }

    private func monthDay(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Locale(identifier: "zh_CN"), calendar: calendar, timeZone: calendar.timeZone)
            .month(.wide).day())
            .replacingOccurrences(of: "月", with: " 月 ")
            .replacingOccurrences(of: "日", with: " 日")
    }

    private func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Locale(identifier: "zh_CN"), calendar: calendar, timeZone: calendar.timeZone)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private static func duration(_ value: Duration, remaining: Bool = false) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = remaining && value < .seconds(3600)
            ? (value < .seconds(60) ? [.seconds] : [.minutes]) : [.hours, .minutes]
        return max(.zero, value).formatted(.units(allowed: units, width: .wide).locale(Locale(identifier: "zh_CN")))
            .replacingOccurrences(of: "小时", with: " 小时 ")
            .replacingOccurrences(of: "分钟", with: remaining ? " 分钟" : " 分")
            .replacingOccurrences(of: "秒钟", with: " 秒")
            .trimmingCharacters(in: .whitespaces)
    }
}

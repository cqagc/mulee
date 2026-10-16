import Foundation
import MuleeCore

/// 任务展示文案的唯一入口。日期依赖可注入，测试不受系统时间影响。
struct TaskPresentation {
    /// 数字和文件大小跟随系统语言（中文系统显示「893 字节」，英文系统显示「893 bytes」）。
    static let displayLocale = Locale.autoupdatingCurrent

    let task: DownloadTask
    let now: Date
    let calendar: Calendar
    let schedule: TransferScheduleController.Configuration?
    let seedingAction: SettingsModel.SeedingAction

    init(
        task: DownloadTask, now: Date = .now, calendar: Calendar = .current,
        seedingAction: SettingsModel.SeedingAction = .throttle,
        schedule: TransferScheduleController.Configuration? = nil
    ) {
        self.task = task
        self.now = now
        self.calendar = calendar
        self.seedingAction = seedingAction
        self.schedule = schedule
    }

    var typeLabel: String {
        switch task.kind {
        case .http: "HTTP"
        case .bittorrent: "BT"
        case .ed2k: "ED2K"
        case .video: String(localized: "视频")
        }
    }

    var size: String { task.totalBytes.map(Self.bytes) ?? String(localized: "大小未知") }

    var metadata: String {
        if task.status == .extracting, let rule = task.postDownload.matchedRuleName {
            return String(localized: "\(size) · 命中解压规则「\(rule)」")
        }
        switch task.detail {
        case .http(let connections):
            // 只有正在下载时连接数才有意义；排队、暂停、完成时只显示大小。
            guard task.status == .downloading, connections > 0 else { return size }
            return String(localized: "\(size) · \(connections) 线程")
        case .bittorrent(let files, let selected, let peers, let ratio):
            if task.status == .seeding {
                return String(localized: "\(size) · 分享率 \(ratio.formatted(.number.precision(.fractionLength(2)))) / 1.00")
            }
            return String(localized: "\(files) 个文件，已选 \(selected) 个 · \(peers) 个节点")
        case .ed2k(_, let info):
            if info.sourceCount > 0 {
                let queue = info.queueRank.map { String(localized: "，排队第 \($0) 位") } ?? ""
                return String(localized: "\(size) · \(info.sourceCount) 个来源\(queue)")
            }
            let lastSeen = info.lastCompleteSourceSeen.map { String(localized: "，完整源最后出现于 \(monthDay($0))") } ?? String(localized: "，尚未见到完整源")
            return String(localized: "\(size) · 暂无来源\(lastSeen)")
        case .video(let site, let quality, let danmaku):
            return "\(site.displayName) · \(Self.qualityTitle(quality))\(danmaku ? String(localized: " · 弹幕转 ASS") : "")"
        }
    }

    private static func qualityTitle(_ value: String) -> String {
        switch value {
        case "自动": String(localized: "自动")
        case "1080P 高码率": String(localized: "1080P 高码率")
        case "2160p HEVC，兼容优先": String(localized: "2160p HEVC，兼容优先")
        default: value
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
        if task.status == .completed, [.waitingForVolumes, .failed, .cancelled].contains(task.postDownload.extractionState) {
            return .waiting
        }
        return switch task.status {
        case .waitingForSources, .failed: .waiting
        case .extracting, .seeding: .success
        case .completed: .completed
        default: .accent
        }
    }

    var progressText: String {
        switch task.status {
        case .extracting: String(localized: "解压中 · \(percent)")
        case .seeding: String(localized: "做种 \(percent) · 到 1:1 后\(seedingAction == .stop ? String(localized: "停止") : String(localized: "降速"))")
        case .postProcessing: String(localized: "\(percent) · 合并音视频")
        case .completed: extractionStatus ?? size
        default: "\(percent) · \(receivedAndTotal)"
        }
    }

    var inspectorProgressText: String {
        guard [.downloading, .waitingForSources, .paused].contains(task.status), task.kind == .ed2k, let total = task.totalBytes else { return progressText }
        return String(localized: "\(percent) · 已收到 \(Self.bytes(task.receivedBytes))，剩余 \(Self.bytes(max(0, total - task.receivedBytes)))")
    }

    var schedulePauseTitle: String? {
        guard task.pauseReason == .schedule || (task.status == .queued && schedule?.enabled == true
            && schedule?.isValid == true && schedule?.isActive(at: now, calendar: calendar) == false) else { return nil }
        if let next = schedule?.nextStart(after: now, calendar: calendar) {
            return String(localized: "按计划暂停，\(time(next)) 自动继续")
        }
        return String(localized: "按计划暂停")
    }

    var statusTitle: String {
        if [.paused, .queued].contains(task.status), task.pauseReason != .diskSpace, let schedulePauseTitle {
            return schedulePauseTitle
        }
        return switch task.status {
        case .downloading: Self.rate(task.downloadRate)
        case .waitingForSources: String(localized: "等待来源")
        case .postProcessing: String(localized: "处理中")
        case .extracting: String(localized: "解压中")
        case .seeding: "↑ \(Self.rate(task.uploadRate))"
        case .completed: extractionStatus ?? String(localized: "已完成")
        case .paused: task.pauseReason == .diskSpace ? String(localized: "因磁盘空间不足已暂停") : String(localized: "已暂停")
        case .failed: String(localized: "需要处理")
        case .queued: String(localized: "排队中")
        case .engineUnavailable: String(localized: "引擎未接入")
        }
    }

    var statusSubtitle: String {
        if [.paused, .queued].contains(task.status), schedulePauseTitle != nil { return "" }
        return switch task.status {
        case .downloading: task.estimatedTimeRemaining.map { String(localized: "剩 \(Self.duration($0, remaining: true))") } ?? String(localized: "正在下载")
        case .waitingForSources: longTail.map { String(localized: "已挂 \(days(since: $0.waitingSince)) 天") } ?? String(localized: "耐心等待")
        case .postProcessing: String(localized: "即将完成")
        case .extracting:
            task.postDownload.extractionState == nil && task.postDownload.filenameEncoding != nil
                ? String(localized: "已修复文件名编码") : String(localized: "正在解压文件")
        case .seeding: String(localized: "做种中")
        case .completed:
            switch task.postDownload.extractionState {
            case .waitingForVolumes: String(localized: "其余分卷下完后继续")
            case .queued: String(localized: "正在处理其他压缩包")
            case .failed, .cancelled: task.postDownload.extractionFailure ?? String(localized: "原压缩包已保留")
            case .succeeded: extractedItems.first?.lastPathComponent ?? String(localized: "文件已准备好")
            default: task.completedAt.map(time) ?? ""
            }
        case .paused: ""
        case .failed: task.errorMessage ?? String(localized: "可稍后重试")
        case .queued: task.kind == .video && task.engineTaskID == nil ? String(localized: "正在准备视频工具") : String(localized: "等待空位")
        case .engineUnavailable: String(localized: "暂时只记录链接")
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
    var canPauseOrResume: Bool { [.downloading, .waitingForSources, .queued, .paused, .seeding].contains(task.status) }
    var pauseTitle: String { task.status == .paused ? String(localized: "继续") : String(localized: "暂停") }
    var pauseSymbol: MuleeSymbol { task.status == .paused ? .resume : .pause }

    var longTail: LongTailInfo? {
        if case .ed2k(_, let info) = task.detail { info } else { nil }
    }

    var longTailStatus: String {
        guard task.status == .waitingForSources || task.status == .downloading else { return statusTitle }
        if task.status == .downloading, task.downloadRate > 0 { return String(localized: "正在下载") }
        return longTail?.queueRank.map { String(localized: "排队中，第 \($0) 位") } ?? String(localized: "等待来源")
    }

    var sourceSummary: String {
        guard let info = longTail else { return "" }
        return String(localized: "\(info.sourceCount) 个（\(info.completeSourceCount) 个完整）")
    }

    var lastCompleteSource: String {
        guard let date = longTail?.lastCompleteSourceSeen else { return String(localized: "尚未见到") }
        let count = days(since: date)
        return count == 0 ? String(localized: "今天") : String(localized: "\(count) 天前")
    }

    var waitingDuration: String { longTail.map { String(localized: "\(days(since: $0.waitingSince)) 天") } ?? "" }
    var transferDuration: String { longTail.map { Self.duration($0.activeTransferDuration) } ?? "" }
    var extractionSetting: String? {
        guard task.kind != .video else { return nil }
        return task.postDownload.autoExtract ? String(localized: "开") : String(localized: "关")
    }
    var showsPostDownload: Bool {
        extractionSetting != nil || extractionStatus != nil || task.status == .extracting
            || task.postDownload.matchedRuleName != nil || task.postDownload.extractionFailure != nil
            || !extractedItems.isEmpty || !(task.postDownload.extractionWarnings ?? []).isEmpty || hash != nil
    }
    var filenameEncoding: String {
        guard let encoding = task.postDownload.filenameEncoding else { return String(localized: "自动检测") }
        return task.postDownload.extractionState == nil ? String(localized: "自动检测（\(encoding)）") : encoding
    }
    var extractedItems: [URL] { task.postDownload.extractedItems ?? [] }

    var extractionStatus: String? {
        switch task.postDownload.extractionState {
        case .queued: String(localized: "等待解压")
        case .waitingForVolumes: String(localized: "等待其余分卷")
        case .extracting: String(localized: "解压中")
        case .succeeded: String(localized: "已解压")
        case .failed: String(localized: "解压未完成")
        case .cancelled: String(localized: "解压已取消")
        case nil: nil
        }
    }

    var hash: String? {
        if case .ed2k(let hash, _) = task.detail { "ED2K \(hash)" } else { nil }
    }

    /// 文件大小与访达一致，按十进制换算（.file）。
    static func bytes(_ value: Int64) -> String {
        let style = ByteCountFormatStyle(style: .file, allowedUnits: .all, spellsOutZero: false,
                                         includesActualByteCount: false, locale: Self.displayLocale)
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
        progress.formatted(.percent.precision(.fractionLength(0)).locale(Self.displayLocale))
    }

    private var receivedAndTotal: String {
        guard let total = task.totalBytes, total > 0 else { return String(localized: "已收到 \(Self.bytes(task.receivedBytes))") }
        let units: ByteCountFormatStyle.Units = total >= 1_000_000_000 ? .gb : total >= 1_000_000 ? .mb : .kb
        let style = ByteCountFormatStyle(style: .file, allowedUnits: units, spellsOutZero: false, includesActualByteCount: false, locale: Self.displayLocale)
        let received = max(0, task.receivedBytes).formatted(style)
        let number = received.split(separator: " ").first.map(String.init) ?? received
        return "\(number) / \(total.formatted(style))"
    }

    private static func clamped(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    private func days(since date: Date) -> Int {
        max(0, calendar.dateComponents([.day], from: date, to: now).day ?? 0)
    }

    private func monthDay(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Self.displayLocale, calendar: calendar, timeZone: calendar.timeZone)
            .month(.wide).day())
            .replacingOccurrences(of: "月", with: " 月 ")
            .replacingOccurrences(of: "日", with: " 日")
    }

    private func time(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(locale: Self.displayLocale, calendar: calendar, timeZone: calendar.timeZone)
            .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    private static func duration(_ value: Duration, remaining: Bool = false) -> String {
        let units: Set<Duration.UnitsFormatStyle.Unit> = remaining && value < .seconds(3600)
            ? (value < .seconds(60) ? [.seconds] : [.minutes]) : [.hours, .minutes]
        return max(.zero, value).formatted(.units(allowed: units, width: .wide).locale(Self.displayLocale))
            .replacingOccurrences(of: "小时", with: " 小时 ")
            .replacingOccurrences(of: "分钟", with: remaining ? " 分钟" : " 分")
            .replacingOccurrences(of: "秒钟", with: " 秒")
            .trimmingCharacters(in: .whitespaces)
    }
}

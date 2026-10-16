import Foundation
import MuleeCore
import Observation

/// 设置窗口里所有设置项。每一项变化时立即写入注入的 UserDefaults。
@Observable
final class SettingsModel {
    /// BT 做种到分享率 1:1 之后的动作。
    enum SeedingAction: String, CaseIterable, Identifiable {
        case stop
        case throttle
        case remove

        static let allCases: [Self] = [.stop, .throttle, .remove]

        var id: Self { self }
    }

    /// 视频默认画质。
    enum VideoQuality: String, CaseIterable, Identifiable {
        case compatible
        case best

        static let allCases: [Self] = [.compatible, .best]

        var id: Self { self }
    }

    /// yt-dlp 更新通道。
    enum YtDlpChannel: String, CaseIterable, Identifiable {
        case stable
        case nightly

        static let allCases: [Self] = [.stable, .nightly]

        var id: Self { self }
    }

    /// 压缩包内文件名的编码。
    enum FilenameEncoding: String, CaseIterable, Identifiable {
        case auto
        case gbk
        case big5
        case shiftJIS

        static let allCases: [Self] = [.auto, .gbk, .big5, .shiftJIS]

        var id: Self { self }
    }

    /// 解压成功后对原压缩包的处理。
    enum OriginalArchiveAction: String, CaseIterable, Identifiable {
        case keep
        case trash
        case delete

        static let allCases: [Self] = [.keep, .trash, .delete]

        var id: Self { self }
    }

    /// UserDefaults 里的键。
    enum Key {
        static let closeKeepsRunning = "general.closeKeepsRunning"
        static let launchAtLogin = "general.launchAtLogin"
        static let preventSleep = "general.preventSleep"
        static let allowSleepWhenDone = "general.allowSleepWhenDone"
        static let watchClipboard = "general.watchClipboard"
        static let notifyOnComplete = "general.notifyOnComplete"
        static let notifyOnFailure = "general.notifyOnFailure"
        static let notificationSound = "general.notificationSound"
        static let whenAllDone = "general.whenAllDone"
        static let saveDirectory = "download.saveDirectory"
        static let maxConcurrentTasks = "download.maxConcurrentTasks"
        static let httpThreads = "download.httpThreads"
        static let diskReserveEnabled = "download.diskReserveEnabled"
        static let diskReserveGB = "download.diskReserveGB"
        static let downloadLimit = "network.downloadLimitMBps"
        static let uploadLimit = "network.uploadLimitMBps"
        static let slowModeDownloadMBps = "network.slowModeDownloadMBps"
        static let slowModeUploadMBps = "network.slowModeUploadMBps"
        static let slowModeOnExpensive = "network.slowModeOnExpensive"
        static let scheduledLimit = "network.scheduledLimit"
        static let scheduleStart = "network.scheduleStart"
        static let scheduleEnd = "network.scheduleEnd"
        static let scheduledDownloadLimit = "network.scheduledDownloadLimitMBps"
        static let scheduledUploadLimit = "network.scheduledUploadLimitMBps"
        static let diskCacheMB = "network.diskCacheMB"
        static let portMapping = "network.portMapping"
        static let seedingAction = "bt.seedingAction"
        static let privateIgnoresRatio = "bt.privateIgnoresRatio"
        static let btPort = "bt.port"
        static let publicTrackersEnabled = "bt.publicTrackersEnabled"
        static let trackerSubscriptions = "bt.trackerSubscriptions"
        static let customTrackers = "bt.customTrackers"
        static let blockLeechingClients = "bt.blockLeechingClients"
        static let skipJunkFiles = "bt.skipJunkFiles"
        static let junkFilePatterns = "bt.junkFilePatterns"
        static let seedTimeLimitMinutes = "bt.seedTimeLimitMinutes"
        static let seedInactiveLimitMinutes = "bt.seedInactiveLimitMinutes"
        static let privateMinSeedMinutes = "bt.privateMinSeedMinutes"
        static let ipBlocklistPath = "bt.ipBlocklistPath"
        static let ed2kTCPPort = "ed2k.tcpPort"
        static let ed2kUDPPort = "ed2k.udpPort"
        static let ed2kShare = "ed2k.shareCompleted"
        static let ed2kObfuscation = "ed2k.obfuscation"
        static let ed2kConnectToServers = "ed2k.connectToServers"
        static let ed2kEnableKad = "ed2k.enableKad"
        static let videoQuality = "video.quality"
        static let ytDlpChannel = "video.ytDlpChannel"
        static let updateBeforeRetry = "video.updateBeforeRetry"
        static let danmakuToASS = "video.danmakuToASS"
        static let ccSubtitles = "video.ccSubtitles"
        static let autoExtract = "unzip.autoExtract"
        static let detectPagePassword = "unzip.detectPagePassword"
        static let readArchiveComment = "unzip.readArchiveComment"
        static let filenameEncoding = "unzip.filenameEncoding"
        static let originalAction = "unzip.originalAction"
        static let extractNested = "unzip.extractNested"
    }

    /// 全局限速可选值（MB/s），0 表示不限速。
    static let downloadLimitOptions = [0, 1, 5, 10, 20]
    static let uploadLimitOptions: [Double] = [0, 0.5, 1, 2, 5, 10]
    static let httpThreadOptions = [1, 4, 8, 16]
    static let maxConcurrentTasksRange = 1...10
    static let diskCacheRange = 32.0...512.0

    static var defaultSaveDirectory: String {
        URL.downloadsDirectory.appending(path: "Mulee", directoryHint: .notDirectory).path(percentEncoded: false)
    }

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: 通用
    var closeKeepsRunning: Bool { didSet { defaults.set(closeKeepsRunning, forKey: Key.closeKeepsRunning) } }
    var launchAtLogin: Bool { didSet { defaults.set(launchAtLogin, forKey: Key.launchAtLogin) } }
    var preventSleep: Bool { didSet { defaults.set(preventSleep, forKey: Key.preventSleep) } }
    var allowSleepWhenDone: Bool { didSet { defaults.set(allowSleepWhenDone, forKey: Key.allowSleepWhenDone) } }
    var watchClipboard: Bool { didSet { defaults.set(watchClipboard, forKey: Key.watchClipboard) } }
    var notifyOnComplete: Bool { didSet { defaults.set(notifyOnComplete, forKey: Key.notifyOnComplete) } }
    var notifyOnFailure: Bool { didSet { defaults.set(notifyOnFailure, forKey: Key.notifyOnFailure) } }
    var notificationSound: Bool { didSet { defaults.set(notificationSound, forKey: Key.notificationSound) } }
    var whenAllDone: WhenAllDoneAction { didSet { defaults.set(whenAllDone.rawValue, forKey: Key.whenAllDone) } }

    // MARK: 下载
    var saveDirectory: String { didSet { defaults.set(saveDirectory, forKey: Key.saveDirectory) } }
    var maxConcurrentTasks: Int { didSet { defaults.set(maxConcurrentTasks, forKey: Key.maxConcurrentTasks) } }
    var httpThreads: Int { didSet { defaults.set(httpThreads, forKey: Key.httpThreads) } }
    var diskReserveEnabled: Bool { didSet { defaults.set(diskReserveEnabled, forKey: Key.diskReserveEnabled) } }
    var diskReserveGB: Int {
        didSet {
            let clamped = min(500, max(1, diskReserveGB))
            if clamped != diskReserveGB { diskReserveGB = clamped }
            defaults.set(diskReserveGB, forKey: Key.diskReserveGB)
        }
    }

    // MARK: 网络
    var downloadLimit: Int { didSet { defaults.set(downloadLimit, forKey: Key.downloadLimit) } }
    var uploadLimit: Double { didSet { defaults.set(uploadLimit, forKey: Key.uploadLimit) } }
    var slowModeDownloadMBps: Double { didSet { defaults.set(slowModeDownloadMBps, forKey: Key.slowModeDownloadMBps) } }
    var slowModeUploadMBps: Double { didSet { defaults.set(slowModeUploadMBps, forKey: Key.slowModeUploadMBps) } }
    var slowModeOnExpensive: Bool { didSet { defaults.set(slowModeOnExpensive, forKey: Key.slowModeOnExpensive) } }
    var scheduledLimit: Bool { didSet { defaults.set(scheduledLimit, forKey: Key.scheduledLimit) } }
    var scheduleStart: Date { didSet { defaults.set(scheduleStart, forKey: Key.scheduleStart) } }
    var scheduleEnd: Date { didSet { defaults.set(scheduleEnd, forKey: Key.scheduleEnd) } }
    var scheduledDownloadLimit: Int { didSet { defaults.set(scheduledDownloadLimit, forKey: Key.scheduledDownloadLimit) } }
    var scheduledUploadLimit: Double { didSet { defaults.set(scheduledUploadLimit, forKey: Key.scheduledUploadLimit) } }
    var diskCacheMB: Double { didSet { defaults.set(diskCacheMB, forKey: Key.diskCacheMB) } }
    var portMapping: Bool { didSet { defaults.set(portMapping, forKey: Key.portMapping) } }

    // MARK: BT
    var seedingAction: SeedingAction { didSet { defaults.set(seedingAction.rawValue, forKey: Key.seedingAction) } }
    var privateIgnoresRatio: Bool { didSet { defaults.set(privateIgnoresRatio, forKey: Key.privateIgnoresRatio) } }
    var btPort: Int { didSet { defaults.set(btPort, forKey: Key.btPort) } }
    var publicTrackersEnabled: Bool { didSet { defaults.set(publicTrackersEnabled, forKey: Key.publicTrackersEnabled) } }
    var trackerSubscriptions: String { didSet { defaults.set(trackerSubscriptions, forKey: Key.trackerSubscriptions) } }
    var customTrackers: String { didSet { defaults.set(customTrackers, forKey: Key.customTrackers) } }
    var blockLeechingClients: Bool { didSet { defaults.set(blockLeechingClients, forKey: Key.blockLeechingClients) } }

    var skipJunkFiles: Bool { didSet { defaults.set(skipJunkFiles, forKey: Key.skipJunkFiles) } }
    var junkFilePatterns: [String] { didSet { defaults.set(junkFilePatterns, forKey: Key.junkFilePatterns) } }
    var seedTimeLimitMinutes: Int { didSet { defaults.set(seedTimeLimitMinutes, forKey: Key.seedTimeLimitMinutes) } }
    var seedInactiveLimitMinutes: Int { didSet { defaults.set(seedInactiveLimitMinutes, forKey: Key.seedInactiveLimitMinutes) } }
    var privateMinSeedMinutes: Int { didSet { defaults.set(privateMinSeedMinutes, forKey: Key.privateMinSeedMinutes) } }
    var ipBlocklistPath: String { didSet { defaults.set(ipBlocklistPath, forKey: Key.ipBlocklistPath) } }

    // MARK: 电驴
    var ed2kTCPPort: Int { didSet { defaults.set(ed2kTCPPort, forKey: Key.ed2kTCPPort) } }
    var ed2kUDPPort: Int { didSet { defaults.set(ed2kUDPPort, forKey: Key.ed2kUDPPort) } }
    var ed2kShare: Bool { didSet { defaults.set(ed2kShare, forKey: Key.ed2kShare) } }
    var ed2kObfuscation: Bool { didSet { defaults.set(ed2kObfuscation, forKey: Key.ed2kObfuscation) } }
    var ed2kConnectToServers: Bool { didSet { defaults.set(ed2kConnectToServers, forKey: Key.ed2kConnectToServers) } }
    var ed2kEnableKad: Bool { didSet { defaults.set(ed2kEnableKad, forKey: Key.ed2kEnableKad) } }

    // MARK: 视频
    var videoQuality: VideoQuality { didSet { defaults.set(videoQuality.rawValue, forKey: Key.videoQuality) } }
    var ytDlpChannel: YtDlpChannel { didSet { defaults.set(ytDlpChannel.rawValue, forKey: Key.ytDlpChannel) } }
    var updateBeforeRetry: Bool { didSet { defaults.set(updateBeforeRetry, forKey: Key.updateBeforeRetry) } }
    var danmakuToASS: Bool { didSet { defaults.set(danmakuToASS, forKey: Key.danmakuToASS) } }
    var ccSubtitles: Bool { didSet { defaults.set(ccSubtitles, forKey: Key.ccSubtitles) } }

    // MARK: 解压
    var autoExtract: Bool { didSet { defaults.set(autoExtract, forKey: Key.autoExtract) } }
    var detectPagePassword: Bool { didSet { defaults.set(detectPagePassword, forKey: Key.detectPagePassword) } }
    var readArchiveComment: Bool { didSet { defaults.set(readArchiveComment, forKey: Key.readArchiveComment) } }
    var filenameEncoding: FilenameEncoding { didSet { defaults.set(filenameEncoding.rawValue, forKey: Key.filenameEncoding) } }
    var originalAction: OriginalArchiveAction { didSet { defaults.set(originalAction.rawValue, forKey: Key.originalAction) } }
    var extractNested: Bool { didSet { defaults.set(extractNested, forKey: Key.extractNested) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        slowModeOnExpensive = Self.bool(defaults, Key.slowModeOnExpensive, true)
        slowModeUploadMBps = defaults.object(forKey: Key.slowModeUploadMBps) as? Double ?? 0.2
        slowModeDownloadMBps = defaults.object(forKey: Key.slowModeDownloadMBps) as? Double ?? 1
        diskReserveGB = min(500, max(1, Self.int(defaults, Key.diskReserveGB, 10)))
        diskReserveEnabled = Self.bool(defaults, Key.diskReserveEnabled, true)
        whenAllDone = Self.raw(defaults, Key.whenAllDone, .none)
        notificationSound = Self.bool(defaults, Key.notificationSound, false)
        notifyOnFailure = Self.bool(defaults, Key.notifyOnFailure, true)
        notifyOnComplete = Self.bool(defaults, Key.notifyOnComplete, true)
        closeKeepsRunning = Self.bool(defaults, Key.closeKeepsRunning, true)
        launchAtLogin = Self.bool(defaults, Key.launchAtLogin, false)
        preventSleep = Self.bool(defaults, Key.preventSleep, true)
        allowSleepWhenDone = Self.bool(defaults, Key.allowSleepWhenDone, true)
        watchClipboard = Self.bool(defaults, Key.watchClipboard, false)
        saveDirectory = defaults.string(forKey: Key.saveDirectory) ?? Self.defaultSaveDirectory
        maxConcurrentTasks = Self.int(defaults, Key.maxConcurrentTasks, 5)
        httpThreads = Self.int(defaults, Key.httpThreads, 8)
        downloadLimit = Self.int(defaults, Key.downloadLimit, 0)
        uploadLimit = defaults.object(forKey: Key.uploadLimit) as? Double ?? 2
        scheduledLimit = Self.bool(defaults, Key.scheduledLimit, false)
        scheduleStart = defaults.object(forKey: Key.scheduleStart) as? Date
            ?? Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: Date()) ?? Date()
        scheduleEnd = defaults.object(forKey: Key.scheduleEnd) as? Date
            ?? Calendar.current.date(bySettingHour: 18, minute: 0, second: 0, of: Date()) ?? Date()
        scheduledDownloadLimit = Self.int(defaults, Key.scheduledDownloadLimit, 5)
        scheduledUploadLimit = defaults.object(forKey: Key.scheduledUploadLimit) as? Double ?? 2
        diskCacheMB = defaults.object(forKey: Key.diskCacheMB) as? Double ?? 128
        portMapping = Self.bool(defaults, Key.portMapping, true)
        seedingAction = Self.raw(defaults, Key.seedingAction, .throttle)
        privateIgnoresRatio = Self.bool(defaults, Key.privateIgnoresRatio, true)
        btPort = Self.int(defaults, Key.btPort, 51413)
        publicTrackersEnabled = Self.bool(defaults, Key.publicTrackersEnabled, true)
        trackerSubscriptions = defaults.string(forKey: Key.trackerSubscriptions) ?? PublicTrackerList.defaultSubscriptions
        customTrackers = defaults.string(forKey: Key.customTrackers) ?? ""
        blockLeechingClients = Self.bool(defaults, Key.blockLeechingClients, false)
        skipJunkFiles = Self.bool(defaults, Key.skipJunkFiles, true)
        junkFilePatterns = defaults.stringArray(forKey: Key.junkFilePatterns) ?? TorrentEngineSettings.defaultJunkFilePatterns
        seedTimeLimitMinutes = Self.int(defaults, Key.seedTimeLimitMinutes, 0)
        seedInactiveLimitMinutes = Self.int(defaults, Key.seedInactiveLimitMinutes, 0)
        privateMinSeedMinutes = Self.int(defaults, Key.privateMinSeedMinutes, 0)
        ipBlocklistPath = defaults.string(forKey: Key.ipBlocklistPath) ?? ""
        ed2kTCPPort = Self.int(defaults, Key.ed2kTCPPort, 4662)
        ed2kUDPPort = Self.int(defaults, Key.ed2kUDPPort, 4672)
        ed2kShare = Self.bool(defaults, Key.ed2kShare, true)
        ed2kObfuscation = Self.bool(defaults, Key.ed2kObfuscation, true)
        ed2kConnectToServers = Self.bool(defaults, Key.ed2kConnectToServers, true)
        ed2kEnableKad = Self.bool(defaults, Key.ed2kEnableKad, true)
        videoQuality = Self.raw(defaults, Key.videoQuality, .compatible)
        ytDlpChannel = Self.raw(defaults, Key.ytDlpChannel, .stable)
        updateBeforeRetry = Self.bool(defaults, Key.updateBeforeRetry, true)
        danmakuToASS = Self.bool(defaults, Key.danmakuToASS, true)
        ccSubtitles = Self.bool(defaults, Key.ccSubtitles, true)
        autoExtract = Self.bool(defaults, Key.autoExtract, true)
        detectPagePassword = Self.bool(defaults, Key.detectPagePassword, true)
        readArchiveComment = Self.bool(defaults, Key.readArchiveComment, true)
        filenameEncoding = Self.raw(defaults, Key.filenameEncoding, .auto)
        originalAction = Self.raw(defaults, Key.originalAction, .trash)
        extractNested = Self.bool(defaults, Key.extractNested, false)
    }

    private static func bool(_ defaults: UserDefaults, _ key: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? fallback
    }

    private static func int(_ defaults: UserDefaults, _ key: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? fallback
    }

    private static func raw<T: RawRepresentable>(_ defaults: UserDefaults, _ key: String, _ fallback: T) -> T where T.RawValue == String {
        guard let value = defaults.string(forKey: key), let parsed = T(rawValue: value) else { return fallback }
        return parsed
    }
}

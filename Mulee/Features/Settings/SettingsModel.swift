import Foundation
import Observation

/// 设置窗口里所有设置项。每一项变化时立即写入注入的 UserDefaults。
@Observable
final class SettingsModel {
    /// BT 做种到分享率 1:1 之后的动作。
    enum SeedingAction: String, CaseIterable, Identifiable {
        case stop
        case throttle

        static let allCases: [Self] = [.stop, .throttle]

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
        static let saveDirectory = "download.saveDirectory"
        static let maxConcurrentTasks = "download.maxConcurrentTasks"
        static let httpThreads = "download.httpThreads"
        static let downloadLimit = "network.downloadLimitMBps"
        static let uploadLimit = "network.uploadLimitMBps"
        static let scheduledLimit = "network.scheduledLimit"
        static let diskCacheMB = "network.diskCacheMB"
        static let portMapping = "network.portMapping"
        static let seedingAction = "bt.seedingAction"
        static let privateIgnoresRatio = "bt.privateIgnoresRatio"
        static let btPort = "bt.port"
        static let ed2kTCPPort = "ed2k.tcpPort"
        static let ed2kUDPPort = "ed2k.udpPort"
        static let ed2kShare = "ed2k.shareCompleted"
        static let ed2kObfuscation = "ed2k.obfuscation"
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

    // MARK: 下载
    var saveDirectory: String { didSet { defaults.set(saveDirectory, forKey: Key.saveDirectory) } }
    var maxConcurrentTasks: Int { didSet { defaults.set(maxConcurrentTasks, forKey: Key.maxConcurrentTasks) } }
    var httpThreads: Int { didSet { defaults.set(httpThreads, forKey: Key.httpThreads) } }

    // MARK: 网络
    var downloadLimit: Int { didSet { defaults.set(downloadLimit, forKey: Key.downloadLimit) } }
    var uploadLimit: Double { didSet { defaults.set(uploadLimit, forKey: Key.uploadLimit) } }
    var scheduledLimit: Bool { didSet { defaults.set(scheduledLimit, forKey: Key.scheduledLimit) } }
    var diskCacheMB: Double { didSet { defaults.set(diskCacheMB, forKey: Key.diskCacheMB) } }
    var portMapping: Bool { didSet { defaults.set(portMapping, forKey: Key.portMapping) } }

    // MARK: BT
    var seedingAction: SeedingAction { didSet { defaults.set(seedingAction.rawValue, forKey: Key.seedingAction) } }
    var privateIgnoresRatio: Bool { didSet { defaults.set(privateIgnoresRatio, forKey: Key.privateIgnoresRatio) } }
    var btPort: Int { didSet { defaults.set(btPort, forKey: Key.btPort) } }

    // MARK: 电驴
    var ed2kTCPPort: Int { didSet { defaults.set(ed2kTCPPort, forKey: Key.ed2kTCPPort) } }
    var ed2kUDPPort: Int { didSet { defaults.set(ed2kUDPPort, forKey: Key.ed2kUDPPort) } }
    var ed2kShare: Bool { didSet { defaults.set(ed2kShare, forKey: Key.ed2kShare) } }
    var ed2kObfuscation: Bool { didSet { defaults.set(ed2kObfuscation, forKey: Key.ed2kObfuscation) } }

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
        scheduledLimit = Self.bool(defaults, Key.scheduledLimit, true)
        diskCacheMB = defaults.object(forKey: Key.diskCacheMB) as? Double ?? 128
        portMapping = Self.bool(defaults, Key.portMapping, true)
        seedingAction = Self.raw(defaults, Key.seedingAction, .throttle)
        privateIgnoresRatio = Self.bool(defaults, Key.privateIgnoresRatio, true)
        btPort = Self.int(defaults, Key.btPort, 51413)
        ed2kTCPPort = Self.int(defaults, Key.ed2kTCPPort, 4662)
        ed2kUDPPort = Self.int(defaults, Key.ed2kUDPPort, 4672)
        ed2kShare = Self.bool(defaults, Key.ed2kShare, true)
        ed2kObfuscation = Self.bool(defaults, Key.ed2kObfuscation, true)
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

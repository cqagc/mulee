import Foundation

/// 与 Claude Design 原型（第 1 轮）一一对应的示例数据，用于界面开发与预览。
/// 引擎接入之前，App 也用它启动。
public enum MockData {
    private static let day: TimeInterval = 86_400
    private static let gb: Int64 = 1_073_741_824
    private static let mb: Int64 = 1_048_576

    /// 原型里选中的那个电驴长尾任务。
    public static let longTailTask = DownloadTask(
        name: "超魔法大戰 繁中版.rar",
        fileExtension: "rar",
        kind: .ed2k,
        status: .waitingForSources,
        totalBytes: 612 * mb,
        receivedBytes: 251 * mb,
        detail: .ed2k(
            hash: "9F3A0C5E7D21B84A6C0E93F15B71DC21",
            longTail: LongTailInfo(
                queueRank: 14,
                sourceCount: 2,
                completeSourceCount: 1,
                lastCompleteSourceSeen: Date.now.addingTimeInterval(-3 * day),
                waitingSince: Date.now.addingTimeInterval(-12 * day),
                activeTransferDuration: .seconds(6 * 3600 + 12 * 60),
                dailySourceSightings: [0, 2, 0, 0, 1, 3, 0, 0, 0, 1, 0, 2, 0, 1]
            )
        ),
        postDownload: PostDownloadInfo(autoExtract: true, filenameEncoding: "Big5"),
        sourceLink: "ed2k://|file|%E8%B6%85%E9%AD%94%E6%B3%95%E5%A4%A7%E6%88%B0%20%E7%B9%81%E4%B8%AD%E7%89%88.rar|641728512|9F3A0C5E7D21B84A6C0E93F15B71DC21|/"
    )

    public static let tasks: [DownloadTask] = [
        DownloadTask(
            name: "ubuntu-24.04.3-desktop-arm64.iso",
            fileExtension: "iso",
            kind: .http,
            status: .downloading,
            totalBytes: 6_549_825_536,
            receivedBytes: 4_080_218_931,
            downloadRate: 11_744_051,
            estimatedTimeRemaining: .seconds(180),
            detail: .http(connections: 8),
            postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "https://releases.ubuntu.com/24.04.3/ubuntu-24.04.3-desktop-arm64.iso"
        ),
        DownloadTask(
            name: "Big Buck Bunny 4K 合集",
            fileExtension: nil,
            kind: .bittorrent,
            status: .downloading,
            totalBytes: Int64(8.4 * Double(gb)),
            receivedBytes: Int64(2.9 * Double(gb)),
            downloadRate: 6_081_741,
            uploadRate: 31_744,
            estimatedTimeRemaining: .seconds(16 * 60),
            detail: .bittorrent(fileCount: 12, selectedFileCount: 3, peerCount: 46, shareRatio: 0.02),
            postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny"
        ),
        longTailTask,
        DownloadTask(
            name: "城市夜景延时摄影【4K】",
            fileExtension: "mp4",
            kind: .video,
            status: .postProcessing,
            totalBytes: 860 * mb,
            receivedBytes: 826 * mb,
            detail: .video(site: .bilibili, quality: "1080P 高码率", danmakuToASS: true),
            postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "https://www.bilibili.com/video/BV1xx411c7XX"
        ),
        DownloadTask(
            name: "Sintel 原声与设定集.zip",
            fileExtension: "zip",
            kind: .http,
            status: .extracting,
            totalBytes: Int64(1.3 * Double(gb)),
            receivedBytes: Int64(1.3 * Double(gb)),
            detail: .http(connections: 8),
            postDownload: PostDownloadInfo(autoExtract: true, matchedRuleName: "example-share.com", filenameEncoding: "GBK", extractProgress: 0.7),
            sourceLink: "https://example-share.com/files/sintel-ost.zip"
        ),
        DownloadTask(
            name: "debian-13.1.0-arm64-DVD-1.iso",
            fileExtension: "iso",
            kind: .bittorrent,
            status: .seeding,
            totalBytes: Int64(3.9 * Double(gb)),
            receivedBytes: Int64(3.9 * Double(gb)),
            uploadRate: 389_120,
            detail: .bittorrent(fileCount: 1, selectedFileCount: 1, peerCount: 12, shareRatio: 0.64),
            postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "magnet:?xt=urn:btih:6a9759bffd5c0af65319979fb7832189f4f3c35d&dn=debian-13.1.0-arm64-DVD-1.iso"
        ),
        DownloadTask(
            name: "某老游戏资料片 (CD).bin + .cue",
            fileExtension: "bin",
            kind: .ed2k,
            status: .waitingForSources,
            totalBytes: 702 * mb,
            receivedBytes: 21 * mb,
            detail: .ed2k(
                hash: "41C7E2D09A8B3F6E5D4C2B1A09F8E7D6",
                longTail: LongTailInfo(
                    queueRank: nil,
                    sourceCount: 0,
                    completeSourceCount: 0,
                    lastCompleteSourceSeen: Date.now.addingTimeInterval(-74 * day),
                    waitingSince: Date.now.addingTimeInterval(-31 * day),
                    activeTransferDuration: .seconds(40 * 60),
                    dailySourceSightings: Array(repeating: 0, count: 14)
                )
            ),
            postDownload: PostDownloadInfo(autoExtract: true),
            sourceLink: "ed2k://|file|old-game-expansion-cd.bin|736100352|41C7E2D09A8B3F6E5D4C2B1A09F8E7D6|/"
        ),
        DownloadTask(
            name: "开发者大会主题演讲 2026",
            fileExtension: "mp4",
            kind: .video,
            status: .completed,
            totalBytes: Int64(2.1 * Double(gb)),
            receivedBytes: Int64(2.1 * Double(gb)),
            completedAt: Calendar.current.date(bySettingHour: 10, minute: 42, second: 0, of: .now),
            detail: .video(site: .youtube, quality: "2160p HEVC，兼容优先", danmakuToASS: false),
            postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "https://www.youtube.com/watch?v=Example0001"
        ),
    ]

    /// 侧边栏和菜单栏用的「网络正常」状态。
    public static let healthyNetwork = NetworkStatus(
        ed2kID: .high,
        kad: .open,
        bittorrentPortReachable: true,
        p2pRoutedThroughProxy: false,
        p2pExitIP: nil,
        portMappingSucceeded: true
    )

    /// 设置·网络页用的「P2P 走了代理」状态（来自 2026-10-15 技术验证的真实情况）。
    public static let proxiedNetwork = NetworkStatus(
        ed2kID: .low,
        kad: .firewalled,
        bittorrentPortReachable: nil,
        p2pRoutedThroughProxy: true,
        p2pExitIP: "203.0.113.71",
        portMappingSucceeded: false
    )

    public static let unzipRules: [UnzipRule] = [
        UnzipRule(matchKind: .sourceSite, pattern: "example-share.com", keychainItemID: "rule-1", maskedLength: 8, hitCount: 23),
        UnzipRule(matchKind: .filenamePrefix, pattern: "[某字幕组]*", keychainItemID: "rule-2", maskedLength: 6, hitCount: 8),
        UnzipRule(matchKind: .filenameRegex, pattern: #"^SX-\d+.*\.7z$"#, keychainItemID: "rule-3", maskedLength: 10, hitCount: 2),
        UnzipRule(matchKind: .passwordBook, pattern: "以上都没命中时，依次尝试 5 个常用密码", keychainItemID: nil, maskedLength: 0, hitCount: 4),
    ]
}

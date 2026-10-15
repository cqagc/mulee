import Foundation
import MuleeCore

/// 视频设置的值快照；逐任务选项尚未接入。
nonisolated struct VideoEngineConfiguration: Equatable, Sendable {
    var quality: YtDlpQuality = .compatible
    var channel: YtDlpChannel = .stable
    var updateBeforeRetry = true
    var danmaku = true
    var closedCaptions = true

    @MainActor static func configuration(from settings: SettingsModel) -> Self {
        Self(
            quality: settings.videoQuality == .compatible ? .compatible : .best,
            channel: settings.ytDlpChannel == .stable ? .stable : .nightly,
            updateBeforeRetry: settings.updateBeforeRetry,
            danmaku: settings.danmakuToASS,
            closedCaptions: settings.ccSubtitles
        )
    }

    var qualityTitle: String { quality == .compatible ? String(localized: "兼容优先") : String(localized: "画质优先") }

    func apply(to engine: YtDlpEngine) async throws {
        await engine.configureCookies { site in try await VideoLoginStore.shared.cookies(for: site) }
        try await engine.configure(
            quality: quality, cookiesURL: nil,
            subtitles: YtDlpSubtitles(danmaku: danmaku, closedCaptions: closedCaptions),
            channel: channel, updatesEnabled: updateBeforeRetry
        )
    }

    func detail(for link: ParsedLink) -> TaskDetail? {
        guard case .video(_, let site, _) = link else { return nil }
        return .video(site: site, quality: qualityTitle, danmakuToASS: danmaku)
    }
}

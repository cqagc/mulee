import Foundation

struct YtDlpErrorDescriptions: Sendable {
    static func needsUpdate(_ raw: String) -> Bool {
        let text = raw.lowercased()
        return ["unable to extract", "signature extraction", "nsig extraction", "update yt-dlp", "please update", "no video formats found"].contains { text.contains($0) }
    }

    static func message(_ raw: String) -> String {
        let text = raw.lowercased()
        let description: String
        if ["sign in", "login", "cookies", "private video", "members-only", "age-restricted", "registered users", "authentication", "http error 401"].contains(where: text.contains) {
            description = String(localized: "此视频需要登录，请提供有效的 cookies 文件。", bundle: .module)
        } else if ["available in your country", "geo-restricted", "geo restricted", "region"].contains(where: text.contains) {
            description = String(localized: "此视频受地区限制。", bundle: .module)
        } else if ["video unavailable", "removed", "deleted", "not found", "404"].contains(where: text.contains) {
            description = String(localized: "视频不存在或已删除。", bundle: .module)
        } else if text.contains("ffmpeg") || text.contains("ffprobe") {
            let missing = ["not found", "not installed", "required", "no such file", "does not exist"]
            description = missing.contains(where: text.contains)
                ? String(localized: "缺少可用的 ffmpeg，无法合并音视频。", bundle: .module)
                : String(localized: "音视频处理失败，请检查 ffmpeg。", bundle: .module)
        } else if needsUpdate(raw) {
            description = String(localized: "视频网站规则已变化，需要更新 yt-dlp。", bundle: .module)
        } else if ["timed out", "network", "connection", "unable to download", "urlopen", "http error"].contains(where: text.contains) {
            description = String(localized: "网络连接失败，请检查网络与代理。", bundle: .module)
        } else {
            description = String(localized: "视频下载失败。", bundle: .module)
        }
        return String(localized: "\(description)\n原始信息：\(raw)", bundle: .module)
    }
}

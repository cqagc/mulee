import Foundation

/// 重点支持的视频站。其他站点交给 yt-dlp 尽力支持。
public enum VideoSite: String, Sendable, Hashable, Codable {
    case bilibili
    case youtube
    case other

    /// 界面上显示的站点名。
    public var displayName: String {
        switch self {
        case .bilibili: "Bilibili"
        case .youtube: "YouTube"
        case .other: String(localized: "视频网站", bundle: .module)
        }
    }
}

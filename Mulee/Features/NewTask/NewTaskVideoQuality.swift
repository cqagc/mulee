import Foundation

/// 面板保留的视频下载偏好，待视频引擎接入时使用。
enum NewTaskVideoQuality: String, CaseIterable, Identifiable {
    case compatible1080p
    case compatible4K
    case bestQuality
    case audioOnly

    var id: Self { self }

    var title: String {
        switch self {
        case .compatible1080p: String(localized: "兼容优先：1080P 高码率 · H.264 MP4")
        case .compatible4K: "4K HEVC MP4"
        case .audioOnly: String(localized: "仅音频")
        case .bestQuality: String(localized: "画质优先：最高画质 MKV")
        }
    }
}

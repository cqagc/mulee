import Foundation
import MuleeCore
import Observation

/// 每个已识别链接的展示信息与独立选项。
@Observable
final class NewTaskLinkModel: Identifiable {
    let link: ParsedLink
    var files: [TorrentFile]?
    var videoQuality = NewTaskVideoQuality.compatible1080p
    var danmakuToASS = true
    var ccSubtitles = true

    var id: ParsedLink { link }

    init(link: ParsedLink, metadataProvider: any TorrentMetadataProvider) {
        self.link = link
        if case .magnet(let infoHash, _, _) = link {
            files = metadataProvider.files(for: infoHash)
        }
    }

    var selectedSize: Int64? {
        files?.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    var totalSize: Int64? {
        files?.reduce(0) { $0 + $1.size }
    }

    var typeLabel: String {
        switch link {
        case .magnet: "BT"
        case .ed2k: "ED2K"
        case .http: "HTTP"
        case .video: "视频"
        }
    }

    var name: String {
        switch link {
        case .magnet(let infoHash, let displayName, _):
            displayName ?? infoHash
        case .ed2k(let fileName, _, _, _):
            fileName
        case .http(let url, _, _):
            url.lastPathComponent.isEmpty ? (url.host() ?? url.absoluteString) : url.lastPathComponent
        case .video(let url, _, _):
            url.absoluteString
        }
    }

    var detail: String {
        switch link {
        case .magnet:
            "磁力链接 · 正在获取元数据"
        case .ed2k:
            "电驴链接 · 冷门资源可能需要长时间等待来源"
        case .http(let url, let decodedFromThunder, _):
            decodedFromThunder ? "迅雷链接已解析为 \(url.absoluteString)" : "直链 · \(url.host() ?? url.absoluteString)"
        case .video(_, let site, _):
            "\(site.displayName) · 视频链接"
        }
    }

    var sizeDescription: String {
        if let selectedSize, let totalSize {
            return "\(selectedSize.formatted(.byteCount(style: .file))) / \(totalSize.formatted(.byteCount(style: .file)))"
        }
        if case .ed2k(_, let size, _, _) = link {
            return size.formatted(.byteCount(style: .file))
        }
        return "大小未知"
    }
}

import Foundation
import MuleeCore
import Observation

/// 每个已识别链接的展示信息与独立选项。
@Observable
final class NewTaskLinkModel: Identifiable {
    let link: ParsedLink
    var files: [TorrentFile]?
    private(set) var torrentName: String?
    private(set) var metadataError: String?
    var videoQuality = NewTaskVideoQuality.compatible1080p
    var danmakuToASS = true
    var ccSubtitles = true

    var id: ParsedLink { link }

    init(link: ParsedLink, metadataProvider: (any TorrentMetadataProvider)? = nil) {
        self.link = link
        if case .magnet(let infoHash, _, _) = link {
            files = metadataProvider?.files(for: infoHash)
        }
        if case .torrentFile(let url, _) = link, url.isFileURL {
            do {
                let info = try TorrentFileInfo.parse(data: Data(contentsOf: url))
                torrentName = info.name
                files = info.files.map { TorrentFile(name: $0.path, size: $0.size) }
            } catch {
                metadataError = String(localized: "无法读取种子文件，请重新选择完整的 .torrent 文件")
            }
        }
    }

    var filePriorities: [Int]? { files?.map { $0.isSelected ? 4 : 0 } }

    var canStart: Bool {
        metadataError == nil && (files == nil || files?.contains(where: \.isSelected) == true)
    }

    func canDeselect(_ file: TorrentFile) -> Bool {
        !file.isSelected || (files?.filter(\.isSelected).count ?? 0) > 1
    }

    var selectedSize: Int64? {
        files?.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    var totalSize: Int64? {
        files?.reduce(0) { $0 + $1.size }
    }

    var typeLabel: String {
        switch link {
        case .magnet, .torrentFile: "BT"
        case .ed2k: "ED2K"
        case .http: "HTTP"
        case .video: String(localized: "视频")
        }
    }

    var name: String {
        switch link {
        case .magnet(let infoHash, let displayName, _):
            displayName ?? infoHash
        case .torrentFile(let url, _):
            torrentName ?? url.lastPathComponent
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
            String(localized: "磁力链接 · 正在获取元数据")
        case .torrentFile:
            if let metadataError {
                metadataError
            } else if let files {
                String(localized: "BT 种子文件 · \(files.count) 个文件")
            } else {
                String(localized: "BT 种子文件")
            }
        case .ed2k:
            String(localized: "电驴链接 · 冷门资源可能需要长时间等待来源")
        case .http(let url, let decodedFromThunder, _):
            decodedFromThunder ? String(localized: "迅雷链接已解析为 \(url.absoluteString)") : String(localized: "直链 · \(url.host() ?? url.absoluteString)")
        case .video(_, let site, _):
            String(localized: "\(site.displayName) · 视频链接")
        }
    }

    var sizeDescription: String {
        if let selectedSize, let totalSize {
            return "\(selectedSize.formatted(.byteCount(style: .file))) / \(totalSize.formatted(.byteCount(style: .file)))"
        }
        if case .ed2k(_, let size, _, _) = link {
            return size.formatted(.byteCount(style: .file))
        }
        return String(localized: "大小未知")
    }
}

import Foundation
import MuleeCore

/// 只包含预览需要的数据，不启动下载引擎，也不解析 tracker 地址。
nonisolated struct TorrentPreviewModel: Sendable {
    static let maximumFileSize = 20 * 1_024 * 1_024
    static let maximumRows = 500

    let name: String
    let totalSize: Int64
    let fileCount: Int
    let isPrivate: Bool
    let createdBy: String?
    let version: String
    let trackerTiers: [[String]]
    let rows: [TorrentPreviewRow]
    let remainingFileCount: Int

    init(info: TorrentFileInfo) {
        name = info.name
        totalSize = info.totalSize
        fileCount = info.files.count
        isPrivate = info.isPrivate
        createdBy = info.createdBy?.isEmpty == false ? info.createdBy : nil
        version = info.hasV2 ? (info.hasV1 ? "v1 / v2" : "v2") : "v1"
        trackerTiers = info.trackerTiers

        var rows: [TorrentPreviewRow] = []
        var directories = Set<[String]>()
        var visibleFiles = 0
        let hasNamedRoot = info.files.allSatisfy { $0.path.hasPrefix(info.name + "/") }
        for file in info.files.sorted(by: { $0.path < $1.path }) {
            var components = file.path.components(separatedBy: "/")
            if hasNamedRoot, components.count > 1, components.first == info.name { components.removeFirst() }
            var pending: [TorrentPreviewRow] = []
            for depth in 0..<max(0, components.count - 1) {
                let path = Array(components.prefix(depth + 1))
                if !directories.contains(path) {
                    pending.append(TorrentPreviewRow(
                        id: "directory:" + path.joined(separator: "/"),
                        name: components[depth], path: path.joined(separator: "/"), depth: depth, size: nil
                    ))
                }
            }
            pending.append(TorrentPreviewRow(
                id: "file:\(file.index)", name: components.last ?? file.path,
                path: file.path, depth: max(0, components.count - 1), size: file.size
            ))
            // 目录和文件一起计入上限，不留下没有文件的半截分支。
            guard rows.count + pending.count <= Self.maximumRows else { break }
            rows.append(contentsOf: pending)
            for depth in 0..<max(0, components.count - 1) {
                directories.insert(Array(components.prefix(depth + 1)))
            }
            visibleFiles += 1
        }
        self.rows = rows
        remainingFileCount = fileCount - visibleFiles
    }

    static func load(from url: URL) throws -> TorrentPreviewModel {
        guard url.isFileURL else { throw TorrentPreviewError.unreadable }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let size = values.fileSize else {
            throw TorrentPreviewError.unreadable
        }
        guard size <= maximumFileSize else { throw TorrentPreviewError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        // 多读一个字节，防止检查大小之后文件增长绕过上限。
        let data = try handle.read(upToCount: maximumFileSize + 1) ?? Data()
        guard data.count <= maximumFileSize else { throw TorrentPreviewError.tooLarge }
        return TorrentPreviewModel(info: try TorrentFileInfo.parse(data: data))
    }
}

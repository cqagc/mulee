import CryptoKit
import Foundation

/// 本地解析的种子元数据，不启动 BT 引擎或访问网络。
public struct TorrentFileInfo: Sendable, Hashable {
    public let name: String
    public let infoHash: String
    public let files: [TorrentFileEntry]
    public let totalSize: Int64
    public let isPrivate: Bool
    public let trackers: [String]
    public let trackerTiers: [[String]]
    public let createdBy: String?
    public let hasV1: Bool
    public let hasV2: Bool

    public static func parse(data: Data) throws -> TorrentFileInfo {
        var parser = try BencodeParser(data: data)
        guard let root = try parser.parse().dictionary,
              let info = root[Data("info".utf8)]?.dictionary,
              let infoRange = parser.infoRange,
              let nameData = info[Data("name.utf-8".utf8)]?.bytes ?? info[Data("name".utf8)]?.bytes,
              !nameData.isEmpty else { throw BencodeParser.invalid() }
        let name = String(decoding: nameData, as: UTF8.self)
        let hasV2 = info[Data("meta version".utf8)]?.integer == 2
        let hasV1 = !hasV2 || info[Data("pieces".utf8)]?.bytes != nil
        var files: [TorrentFileEntry] = []
        if let values = info[Data("files".utf8)]?.list {
            guard !values.isEmpty, info[Data("length".utf8)] == nil else { throw BencodeParser.invalid() }
            for (index, value) in values.enumerated() {
                guard let file = value.dictionary,
                      let length = file[Data("length".utf8)]?.integer, length >= 0,
                      let path = file[Data("path.utf-8".utf8)]?.list ?? file[Data("path".utf8)]?.list,
                      !path.isEmpty else { throw BencodeParser.invalid() }
                let components = try path.map { component in
                    guard let bytes = component.bytes, !bytes.isEmpty else { throw BencodeParser.invalid() }
                    return String(decoding: bytes, as: UTF8.self)
                }
                files.append(TorrentFileEntry(index: index, path: ([name] + components).joined(separator: "/"), size: length))
            }
        } else if hasV2, info[Data("files".utf8)] == nil, info[Data("length".utf8)] == nil,
                  let tree = info[Data("file tree".utf8)]?.dictionary {
            // v2 的文件树自带完整层级，也可以没有共同根目录。
            try appendV2Files(tree, path: [], files: &files)
            guard !files.isEmpty else { throw BencodeParser.invalid() }
        } else {
            guard info[Data("files".utf8)] == nil,
                  let length = info[Data("length".utf8)]?.integer, length >= 0 else { throw BencodeParser.invalid() }
            files.append(TorrentFileEntry(index: 0, path: name, size: length))
        }
        let total = try files.reduce(Int64(0)) { total, file in
            let (sum, overflow) = total.addingReportingOverflow(file.size)
            guard !overflow else { throw BencodeParser.invalid() }
            return sum
        }
        // Data 的起始索引不一定为 0（调用方可能传入 slice）。
        let rawInfo = Data(Array(data)[infoRange])
        let hash = Insecure.SHA1.hash(data: rawInfo).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 16 ? "0" + hex : hex
        }.joined()
        var trackers: [String] = []
        var trackerTiers: [[String]] = []
        if let announce = root[Data("announce".utf8)]?.bytes {
            trackers.append(String(decoding: announce, as: UTF8.self))
        }
        for tier in root[Data("announce-list".utf8)]?.list ?? [] {
            var tierTrackers: [String] = []
            var seen = Set<String>()
            for tracker in tier.list ?? [] {
                if let bytes = tracker.bytes {
                    let text = String(decoding: bytes, as: UTF8.self)
                    trackers.append(text)
                    if seen.insert(text).inserted { tierTrackers.append(text) }
                }
            }
            if !tierTrackers.isEmpty { trackerTiers.append(tierTrackers) }
        }
        // 保留 announce-list 的层级和顺序，独立 announce 也不能在预览里丢失。
        if let announce = trackers.first, !trackerTiers.joined().contains(announce) {
            trackerTiers.insert([announce], at: 0)
        }
        return TorrentFileInfo(
            name: name, infoHash: hash, files: files, totalSize: total,
            isPrivate: info[Data("private".utf8)]?.integer == 1,
            trackers: Array(Set(trackers)).sorted(),
            trackerTiers: trackerTiers,
            createdBy: root[Data("created by".utf8)]?.bytes.map { String(decoding: $0, as: UTF8.self) },
            hasV1: hasV1, hasV2: hasV2
        )
    }

    private static func appendV2Files(
        _ tree: [Data: BencodeValue], path: [String], files: inout [TorrentFileEntry]
    ) throws {
        if let leaf = tree[Data()] {
            guard tree.count == 1, !path.isEmpty,
                  let attributes = leaf.dictionary,
                  let length = attributes[Data("length".utf8)]?.integer, length >= 0 else {
                throw BencodeParser.invalid()
            }
            files.append(TorrentFileEntry(index: files.count, path: path.joined(separator: "/"), size: length))
            return
        }
        guard !tree.isEmpty else { throw BencodeParser.invalid() }
        for key in tree.keys.sorted(by: { $0.lexicographicallyPrecedes($1) }) {
            guard let child = tree[key]?.dictionary else { throw BencodeParser.invalid() }
            try appendV2Files(child, path: path + [String(decoding: key, as: UTF8.self)], files: &files)
        }
    }
}

import CryptoKit
import Foundation

/// 本地解析的种子元数据，不启动 BT 引擎或访问网络。
public struct TorrentFileInfo: Sendable, Hashable {
    public let name: String
    public let infoHash: String
    public let files: [TorrentFileEntry]
    public let totalSize: Int64
    public let isPrivate: Bool

    public static func parse(data: Data) throws -> TorrentFileInfo {
        var parser = try BencodeParser(data: data)
        guard let root = try parser.parse().dictionary,
              let info = root[Data("info".utf8)]?.dictionary,
              let infoRange = parser.infoRange,
              let nameData = info[Data("name.utf-8".utf8)]?.bytes ?? info[Data("name".utf8)]?.bytes,
              !nameData.isEmpty else { throw BencodeParser.invalid() }
        let name = String(decoding: nameData, as: UTF8.self)
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
        return TorrentFileInfo(
            name: name, infoHash: hash, files: files, totalSize: total,
            isPrivate: info[Data("private".utf8)]?.integer == 1
        )
    }
}

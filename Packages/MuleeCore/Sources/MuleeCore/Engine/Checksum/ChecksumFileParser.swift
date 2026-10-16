import Foundation

public enum ChecksumFileParser {
    public static func sha256(in text: String, filename: String, allowsBareDigest: Bool = false) -> DownloadChecksum? {
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { continue }
            if line.hasPrefix("SHA256 (") || line.hasPrefix("SHA-256 (") {
                guard let start = line.firstIndex(of: "("), let end = line.range(of: ") = ", options: .backwards),
                      line[line.index(after: start)..<end.lowerBound] == filename else { continue }
                return DownloadChecksum(algorithm: .sha256, digest: String(line[end.upperBound...]))
            }
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard let digest = fields.first,
                  let checksum = DownloadChecksum(algorithm: .sha256, digest: String(digest)) else { continue }
            if fields.count == 1 {
                if allowsBareDigest { return checksum }
            } else {
                var name = String(fields[1]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("*") { name.removeFirst() }
                if name.hasPrefix("./") { name.removeFirst(2) }
                if name == filename { return checksum }
            }
        }
        return nil
    }

    public static func discover(for file: URL) throws -> DownloadChecksum? {
        let directory = file.deletingLastPathComponent()
        let candidates = [file.appendingPathExtension("sha256"), directory.appendingPathComponent("SHA256SUMS")]
        for (index, url) in candidates.enumerated() where FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            // 校验清单也不无界读入；异常大的清单留给用户粘贴对应行。
            let limit = 4 * 1024 * 1024
            let data = try handle.read(upToCount: limit + 1) ?? Data()
            guard data.count <= limit, let text = String(data: data, encoding: .utf8) else { continue }
            if let checksum = sha256(in: text, filename: file.lastPathComponent, allowsBareDigest: index == 0) {
                return checksum
            }
        }
        return nil
    }
}

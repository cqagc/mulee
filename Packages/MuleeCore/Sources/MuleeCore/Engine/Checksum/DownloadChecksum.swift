import Foundation

/// 用于下载完整性比对；MD5 和 SHA-1 仅兼容发布者提供的旧校验值，不用于认证。
public struct DownloadChecksum: Sendable, Hashable, Codable {
    public enum Algorithm: String, Sendable, CaseIterable, Codable {
        case md5
        case sha1 = "sha-1"
        case sha256 = "sha-256"

        public var length: Int {
            switch self {
            case .md5: 32
            case .sha1: 40
            case .sha256: 64
            }
        }
    }

    public let algorithm: Algorithm
    public let digest: String
    public var aria2Value: String { "\(algorithm.rawValue)=\(digest)" }

    public init?(algorithm: Algorithm, digest: String) {
        let value = digest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard value.utf8.count == algorithm.length,
              value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.algorithm = algorithm
        self.digest = value
    }

    /// 接受裸哈希、aria2 格式、GNU 校验行与 BSD 校验行。
    public static func parse(_ text: String) -> Self? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let equal = value.lastIndex(of: "=") {
            let prefix = value[..<equal].lowercased().replacingOccurrences(of: "-", with: "")
                .split(whereSeparator: { $0.isWhitespace || $0 == "(" }).first
            let algorithm: Algorithm? = prefix == "sha256" ? .sha256
                : prefix == "sha1" ? .sha1 : prefix == "md5" ? .md5 : nil
            if let algorithm { return Self(algorithm: algorithm, digest: String(value[value.index(after: equal)...])) }
        }
        guard let first = value.split(whereSeparator: \.isWhitespace).first else { return nil }
        return Algorithm.allCases.lazy.compactMap { Self(algorithm: $0, digest: String(first)) }.first
    }

    private enum CodingKeys: String, CodingKey {
        case algorithm, digest
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let algorithm = try container.decode(Algorithm.self, forKey: .algorithm)
        let digest = try container.decode(String.self, forKey: .digest)
        guard let value = Self(algorithm: algorithm, digest: digest) else {
            throw DecodingError.dataCorruptedError(forKey: .digest, in: container, debugDescription: "校验值格式无效")
        }
        self = value
    }
}

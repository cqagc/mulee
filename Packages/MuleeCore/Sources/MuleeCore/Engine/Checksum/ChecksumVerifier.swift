import CryptoKit
import Foundation

public enum ChecksumVerifier {
    @concurrent
    public static func verify(file: URL, expected: DownloadChecksum) async throws -> ChecksumVerification {
        let actual: String
        switch expected.algorithm {
        case .md5: actual = try digest(file: file, using: Insecure.MD5.self)
        case .sha1: actual = try digest(file: file, using: Insecure.SHA1.self)
        case .sha256: actual = try digest(file: file, using: SHA256.self)
        }
        return ChecksumVerification(expected: expected, actual: actual)
    }

    @concurrent
    public static func discover(for file: URL) async throws -> DownloadChecksum? {
        try ChecksumFileParser.discover(for: file)
    }

    private static func digest<H: HashFunction>(file: URL, using: H.Type) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = H()
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

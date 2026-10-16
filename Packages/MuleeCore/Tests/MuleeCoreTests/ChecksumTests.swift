import CryptoKit
import Foundation
import Testing
@testable import MuleeCore

struct ChecksumTests {
    @Test func parsesPastedHashesAndSumFiles() throws {
        let digest = String(repeating: "ab", count: 32)
        #expect(DownloadChecksum.parse("SHA256 (archive.zip) = \(digest.uppercased())")?.digest == digest)
        #expect(DownloadChecksum.parse("sha-256=\(digest)")?.algorithm == .sha256)
        #expect(DownloadChecksum.parse(String(repeating: "0", count: 32))?.algorithm == .md5)
        #expect(DownloadChecksum.parse(String(repeating: "0", count: 40))?.algorithm == .sha1)
        #expect(DownloadChecksum.parse(String(repeating: "g", count: 64)) == nil)
        #expect(ChecksumFileParser.sha256(in: "\(digest) *./archive.zip", filename: "archive.zip")?.digest == digest)
        #expect(ChecksumFileParser.sha256(in: "\(digest)  other.zip", filename: "archive.zip") == nil)
        #expect(ChecksumFileParser.sha256(in: digest, filename: "archive.zip") == nil)
        #expect(ChecksumFileParser.sha256(in: digest, filename: "archive.zip", allowsBareDigest: true)?.digest == digest)
        #expect(ChecksumFileParser.sha256(in: "SHA256 (archive.zip) = \(digest)", filename: "archive.zip")?.digest == digest)
    }

    @Test func discoversOnlyMatchingAdjacentChecksums() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Checksum-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("archive.bin")
        let digest = String(repeating: "a", count: 64)
        try "\(digest)  other.bin\n\(digest)  archive.bin\n".write(to: root.appendingPathComponent("SHA256SUMS"), atomically: true, encoding: .utf8)
        #expect(try ChecksumFileParser.discover(for: file)?.digest == digest)
        let preferred = String(repeating: "b", count: 64)
        try preferred.write(to: file.appendingPathExtension("sha256"), atomically: true, encoding: .utf8)
        #expect(try ChecksumFileParser.discover(for: file)?.digest == preferred)
    }

    @Test(arguments: [
        (DownloadChecksum.Algorithm.md5, "900150983cd24fb0d6963f7d28e17f72"),
        (.sha1, "a9993e364706816aba3e25717850c26c9cd0d89d"),
        (.sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    ])
    func knownHashVectors(_ algorithm: DownloadChecksum.Algorithm, _ digest: String) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Checksum-vector-\(UUID())")
        try Data("abc".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let expected = try #require(DownloadChecksum(algorithm: algorithm, digest: digest))
        #expect(try await ChecksumVerifier.verify(file: file, expected: expected).matches == true)
        let wrong = try #require(DownloadChecksum(algorithm: algorithm, digest: String(repeating: "0", count: algorithm.length)))
        #expect(try await ChecksumVerifier.verify(file: file, expected: wrong).matches == false)
    }

    @Test func hashesAcrossMultipleReadChunksAndHandlesEmptyFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Checksum-stream-\(UUID())")
        defer { try? FileManager.default.removeItem(at: file) }
        let data = Data((0..<(3 * 1024 * 1024 + 37)).map { UInt8($0 % 251) })
        try data.write(to: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let expected = try #require(DownloadChecksum(algorithm: .sha256, digest: digest))
        #expect(try await ChecksumVerifier.verify(file: file, expected: expected).matches == true)
        try Data().write(to: file)
        let empty = try #require(DownloadChecksum.parse("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
        #expect(try await ChecksumVerifier.verify(file: file, expected: empty).matches == true)
    }
}

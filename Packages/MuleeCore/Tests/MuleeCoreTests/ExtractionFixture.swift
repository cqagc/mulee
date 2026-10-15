import Foundation
import Testing
@testable import MuleeCore

struct ExtractionFixture: Sendable {
    static let binary = SevenZipProcess.homebrewBinary
    let root: URL
    let destination: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MuleeExtraction-" + UUID().uuidString, isDirectory: true)
        destination = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    static func withFixture(_ body: (ExtractionFixture) async throws -> Void) async throws {
        let fixture = try ExtractionFixture()
        defer {
            do { try fixture.clean() }
            catch { Issue.record("临时测试目录清理失败：\(error)") }
        }
        try await body(fixture)
    }

    func clean() throws { try FileManager.default.removeItem(at: root) }

    func file(_ name: String, data: Data = Data("虚构星雲資料".utf8)) throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func run(_ arguments: [String]) async throws {
        let executable = try #require(Self.binary)
        let result = try await SevenZipProcess.run(binary: executable, arguments: arguments, directory: root)
        #expect(result.status == 0, "7zz 生成夹具失败：\(result.text)")
    }

    func rule(_ kind: UnzipRule.MatchKind = .filenamePrefix, pattern: String = "*", id: String? = "rule") -> UnzipRule {
        UnzipRule(matchKind: kind, pattern: pattern, keychainItemID: id, maskedLength: 4, hitCount: 0)
    }

    /// 最小 Store ZIP，名称直接写原始字节，UTF-8 标记保持关闭。
    func zip(
        _ name: String = "archive.zip",
        rawName: Data,
        content: Data = Data("fictional payload".utf8),
        attributes: UInt32 = 0,
        unicodePath: String? = nil
    ) throws -> URL {
        try zipEntries(name, entries: [(rawName, content, attributes, unicodePath)])
    }

    func zipEntries(_ name: String, entries: [(name: Data, content: Data, attributes: UInt32, unicodePath: String?)]) throws -> URL {
        var data = Data()
        var central = Data()
        func append(_ value: UInt32, bytes: Int, to target: inout Data) {
            for index in 0..<bytes { target.append(UInt8(truncatingIfNeeded: value >> (index * 8))) }
        }
        func crc32(_ bytes: Data) -> UInt32 {
            var crc: UInt32 = 0xffffffff
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
            }
            return crc ^ 0xffffffff
        }
        for entry in entries {
            let offset = data.count
            let crc = crc32(entry.content)
            var extra = Data()
            if let unicodePath = entry.unicodePath {
                let encoded = Data(unicodePath.utf8)
                append(0x7075, bytes: 2, to: &extra)
                append(UInt32(encoded.count + 5), bytes: 2, to: &extra)
                extra.append(1)
                append(crc32(entry.name), bytes: 4, to: &extra)
                extra.append(encoded)
            }
            append(0x04034b50, bytes: 4, to: &data)
            for value: UInt32 in [20, 0, 0, 0, 0] { append(value, bytes: 2, to: &data) }
            append(crc, bytes: 4, to: &data)
            append(UInt32(entry.content.count), bytes: 4, to: &data)
            append(UInt32(entry.content.count), bytes: 4, to: &data)
            append(UInt32(entry.name.count), bytes: 2, to: &data)
            append(UInt32(extra.count), bytes: 2, to: &data)
            data.append(entry.name)
            data.append(extra)
            data.append(entry.content)
            append(0x02014b50, bytes: 4, to: &central)
            for value: UInt32 in [0x0314, 20, 0, 0, 0, 0] { append(value, bytes: 2, to: &central) }
            append(crc, bytes: 4, to: &central)
            append(UInt32(entry.content.count), bytes: 4, to: &central)
            append(UInt32(entry.content.count), bytes: 4, to: &central)
            append(UInt32(entry.name.count), bytes: 2, to: &central)
            append(UInt32(extra.count), bytes: 2, to: &central)
            for _ in 0..<3 { append(0, bytes: 2, to: &central) }
            append(entry.attributes, bytes: 4, to: &central)
            append(UInt32(offset), bytes: 4, to: &central)
            central.append(entry.name)
            central.append(extra)
        }
        let directoryOffset = data.count
        data.append(central)
        append(0x06054b50, bytes: 4, to: &data)
        for value: UInt32 in [0, 0, UInt32(entries.count), UInt32(entries.count)] { append(value, bytes: 2, to: &data) }
        append(UInt32(central.count), bytes: 4, to: &data)
        append(UInt32(directoryOffset), bytes: 4, to: &data)
        append(0, bytes: 2, to: &data)
        return try file(name, data: data)
    }
}

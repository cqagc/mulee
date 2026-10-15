import Foundation

/// 7zz 的归档级 Comment 字段位于条目分隔线之前，不能把文件名当成密码。
enum ArchiveCommentReader {
    static func password(archive: URL, binary: URL, timeout: Duration) async throws -> String? {
        let output = try await SevenZipProcess.run(
            binary: binary, arguments: ["l", "-slt", "-sccUTF-8", "--", archive.path], timeout: timeout
        )
        // ZIP 注释不带字符集标记，7zz 可能已用错误代码页转码；从 EOCD 取原始字节后复用编码评分。
        if archive.pathExtension.lowercased() == "zip", let bytes = try zipComment(archive) {
            return PasswordTextParser.password(in: decode(bytes))
        }
        if let text = comment(in: output.text) { return PasswordTextParser.password(in: text) }
        return nil
    }

    static func comment(in listing: String) -> String? {
        let lines = Array(listing.components(separatedBy: .newlines).prefix { $0 != "----------" })
        guard let start = lines.firstIndex(where: { $0.hasPrefix("Comment = ") }) else { return nil }
        var comment = [String(lines[start].dropFirst("Comment = ".count))]
        for line in lines.dropFirst(start + 1) {
            if line.contains(" = ") { break }
            comment.append(line)
        }
        return comment.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ bytes: Data) -> String {
        if let utf8 = String(data: bytes, encoding: .utf8) { return utf8 }
        return [ArchiveFilenameEncoding.gbk, .big5, .shiftJIS].compactMap { encoding -> (String, Double)? in
            guard let text = FilenameEncodingDetector.decode(bytes, encoding: encoding) else { return nil }
            return (text, FilenameEncodingDetector.score(filenames: [text], encoding: encoding))
        }.max { $0.1 < $1.1 }?.0 ?? ""
    }

    private static func zipComment(_ archive: URL) throws -> Data? {
        let file = try FileHandle(forReadingFrom: archive)
        defer { file.closeFile() }
        let size = try file.seekToEnd()
        let length = min(size, 65_557)
        try file.seek(toOffset: size - length)
        let data = try file.readToEnd() ?? Data()
        guard data.count >= 22 else { return nil }
        for offset in stride(from: data.count - 22, through: 0, by: -1) {
            guard data[offset..<offset + 4] == Data([0x50, 0x4b, 0x05, 0x06]) else { continue }
            let count = Int(data[offset + 20]) | Int(data[offset + 21]) << 8
            guard offset + 22 + count == data.count else { continue }
            return data.subdata(in: offset + 22..<data.count)
        }
        return nil
    }
}

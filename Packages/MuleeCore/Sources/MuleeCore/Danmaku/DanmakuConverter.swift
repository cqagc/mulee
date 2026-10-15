import Darwin
import Foundation

public struct DanmakuConverter: Sendable {
    public init() {}

    /// 同目录临时文件写完、同步、关闭后再以 rename 原子替换；失败不改变已有 ASS。
    public func convert(xml: URL, to ass: URL, videoSize: CGSize? = nil) throws -> DanmakuStatistics {
        guard xml.standardizedFileURL.resolvingSymlinksInPath() != ass.standardizedFileURL.resolvingSymlinksInPath() else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let temporary = ass.deletingLastPathComponent().appendingPathComponent(".danmaku-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        var sorter = DanmakuCommentSorter(directory: temporary)
        let total = try DanmakuXMLParser().parse(xml: xml) { try sorter.append($0) }
        let outputURL = temporary.appendingPathComponent("output.ass")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        var writer = DanmakuASSWriter(videoSize: videoSize)
        try output.write(contentsOf: Data(writer.header.utf8))
        var written = 0
        try sorter.forEach { comment in
            try Task.checkCancellation()
            if let line = writer.dialogue(for: comment) {
                try output.write(contentsOf: Data(line.utf8))
                written += 1
            }
        }
        try output.synchronize()
        try output.close()
        try Task.checkCancellation()
        guard rename(outputURL.path, ass.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        return DanmakuStatistics(total: total, written: written)
    }

    /// CPU / 文件处理离开引擎 actor，结构化调用保留取消传播。
    @concurrent
    func convertInBackground(xml: URL, to ass: URL, videoSize: CGSize?) async throws -> DanmakuStatistics {
        try convert(xml: xml, to: ass, videoSize: videoSize)
    }
}

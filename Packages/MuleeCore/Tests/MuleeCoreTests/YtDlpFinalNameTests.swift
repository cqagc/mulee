import Foundation
import Testing
@testable import MuleeCore

@Suite("视频成品去掉任务前缀")
struct YtDlpFinalNameTests {
    private let id = UUID().uuidString.lowercased()

    private func makeDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Mulee-final-name-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    @Test("成品和同名字幕、弹幕一起改名")
    func renamesVideoAndSidecars() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try touch("\(id)-城市夜景 延时摄影.mp4", in: root)
        _ = try touch("\(id)-城市夜景 延时摄影.danmaku.ass", in: root)
        _ = try touch("\(id)-城市夜景 延时摄影.zh-CN.srt", in: root)
        let other = try touch("\(id)-其他.mp4", in: root)

        let result = try YtDlpFinalName.finalize(video, jobID: id)

        #expect(result.file.lastPathComponent == "城市夜景 延时摄影.mp4")
        #expect(Set(result.names) == ["城市夜景 延时摄影.mp4", "城市夜景 延时摄影.danmaku.ass", "城市夜景 延时摄影.zh-CN.srt"])
        #expect(FileManager.default.fileExists(atPath: result.file.path))
        #expect(!FileManager.default.fileExists(atPath: video.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    @Test("与已有文件重名时加序号，附属文件序号一致")
    func numbersOnCollision() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try touch("Sintel.mp4", in: root)
        _ = try touch("Sintel (2).danmaku.ass", in: root)
        let video = try touch("\(id)-Sintel.mp4", in: root)
        _ = try touch("\(id)-Sintel.danmaku.ass", in: root)

        let result = try YtDlpFinalName.finalize(video, jobID: id)

        #expect(result.file.lastPathComponent == "Sintel (3).mp4")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Sintel (3).danmaku.ass").path))
    }

    @Test("没有任务前缀时不改名")
    func leavesUnprefixedFiles() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try touch("Big Buck Bunny.mp4", in: root)

        let result = try YtDlpFinalName.finalize(video, jobID: id)

        #expect(result.file == video)
        #expect(result.names.isEmpty)
    }

    @Test("删除任务时按记录找到改名后的文件，不碰同目录其他文件")
    func trashUsesRecordedNames() throws {
        let root = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let video = try touch("\(id)-Sintel.mp4", in: root)
        let unrelated = try touch("Sintel 预告.mp4", in: root)
        let renamed = try YtDlpFinalName.finalize(video, jobID: id)
        var job = YtDlpJob(id: id, url: root, site: .other, directory: root, name: "Sintel")
        job.finalFiles = renamed.names

        try YtDlpFileSafety.trash(job)

        #expect(!FileManager.default.fileExists(atPath: renamed.file.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("旧的 jobs.json 没有 finalFiles 也能读取")
    func decodesOldRecords() throws {
        let json = #"{"id":"\#(id)","url":"https://www.bilibili.com/video/BV1xx411c7XX","site":"bilibili","directory":"file:///tmp/","name":"示例","status":"completed","receivedBytes":0,"retried":false}"#
        let job = try JSONDecoder().decode(YtDlpJob.self, from: Data(json.utf8))
        #expect(job.finalFiles == nil)
    }
}

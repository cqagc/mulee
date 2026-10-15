import Foundation
@testable import MuleeCore

struct DanmakuTestFixture: Sendable {
    let root: URL
    var xml: URL { root.appendingPathComponent("sample.danmaku.xml") }
    var ass: URL { root.appendingPathComponent("sample.danmaku.ass") }

    init() throws {
        var workspace = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { workspace.deleteLastPathComponent() }
        root = workspace.appendingPathComponent("build/danmaku-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func write(_ text: String) throws {
        try Data(text.utf8).write(to: xml)
    }

    func readASS() throws -> String {
        try String(contentsOf: ass, encoding: .utf8)
    }

    func comments(_ body: String) throws -> (Int, [DanmakuComment]) {
        try write("<i>" + body + "</i>")
        var comments: [DanmakuComment] = []
        let total = try DanmakuXMLParser().parse(xml: xml) { comments.append($0) }
        return (total, comments)
    }
}

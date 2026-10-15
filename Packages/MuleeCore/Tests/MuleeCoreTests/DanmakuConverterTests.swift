import Foundation
import Testing
@testable import MuleeCore

struct DanmakuConverterTests {
    @Test(arguments: ["", "<i></i>"])
    func emptyInputCreatesValidHeader(xml: String) throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        try fixture.write(xml)

        let result = try DanmakuConverter().convert(xml: fixture.xml, to: fixture.ass)
        let output = try fixture.readASS()

        #expect(result == DanmakuStatistics(total: 0, written: 0))
        #expect(output.contains("PlayResX: 1920"))
        #expect(output.contains("PlayResY: 1080"))
        #expect(output.contains("[Events]"))
        #expect(!output.contains("Dialogue:"))
    }

    @Test func countsDropsSortsInputAndAtomicallyReplacesExistingASS() throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        try fixture.write("""
        <i>
        <d p="10,1,25,16711680">后出现</d>
        <d p="0,5,25,0">先出现</d>
        <d p="0,7,25,0">高级</d>
        <d p="0,8,25,0">代码</d>
        <d p="bad">错误</d>
        </i>
        """)
        try Data("旧的字幕".utf8).write(to: fixture.ass)
        let old = try FileHandle(forReadingFrom: fixture.ass)
        defer { try? old.close() }

        let result = try DanmakuConverter().convert(xml: fixture.xml, to: fixture.ass)
        let output = try fixture.readASS()

        #expect(result.total == 5)
        #expect(result.written == 2)
        #expect(result.dropped == 3)
        let first = try #require(output.range(of: "先出现"))
        let last = try #require(output.range(of: "后出现"))
        #expect(first.lowerBound < last.lowerBound)
        #expect(try old.readToEnd() == Data("旧的字幕".utf8))
        #expect(FileManager.default.fileExists(atPath: fixture.xml.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
                == ["sample.danmaku.ass", "sample.danmaku.xml"])
    }

    @Test func malformedXMLPreservesExistingASSAndCleansTemporaryFiles() throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        try fixture.write("<i><d p=\"0,1,25,0\">完整</d><d>不完整")
        try Data("保留字幕".utf8).write(to: fixture.ass)

        #expect(throws: (any Error).self) {
            try DanmakuConverter().convert(xml: fixture.xml, to: fixture.ass)
        }

        #expect(try fixture.readASS() == "保留字幕")
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == 2)
    }

    @Test func renameFailureAndSameSourceDestinationAreSafe() throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        try fixture.write("<i><d p=\"0,1,25,0\">测试</d></i>")
        try FileManager.default.createDirectory(at: fixture.ass, withIntermediateDirectories: false)

        #expect(throws: (any Error).self) {
            try DanmakuConverter().convert(xml: fixture.xml, to: fixture.ass)
        }
        #expect(throws: (any Error).self) {
            try DanmakuConverter().convert(xml: fixture.xml, to: fixture.xml)
        }

        #expect(try String(contentsOf: fixture.xml, encoding: .utf8).contains("测试"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).count == 2)
    }

    @Test func externalSortMergesMoreThan32RunsInTimeOrder() throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        var sorter = DanmakuCommentSorter(directory: fixture.root)
        for index in (0..<132_000).reversed() {
            try sorter.append(DanmakuComment(time: Double(index), mode: 1, fontSize: 25,
                                              color: 0, text: "排序", ordinal: index))
        }
        var expected = 0

        try sorter.forEach {
            guard $0.ordinal == expected else { throw CocoaError(.fileReadCorruptFile) }
            expected += 1
        }

        #expect(expected == 132_000)
    }

    @Test func cancelledConversionPreservesDestination() async throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        try fixture.write("<i><d p=\"0,1,25,0\">测试</d></i>")
        try Data("旧字幕".utf8).write(to: fixture.ass)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try DanmakuConverter().convert(xml: fixture.xml, to: fixture.ass)
        }

        await #expect(throws: CancellationError.self) { try await task.value }

        #expect(try fixture.readASS() == "旧字幕")
    }
}

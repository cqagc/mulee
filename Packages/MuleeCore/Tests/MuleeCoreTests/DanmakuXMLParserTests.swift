import Foundation
import Testing
@testable import MuleeCore

struct DanmakuXMLParserTests {
    @Test func parsesModesAndDiscardsAdvancedAndCode() throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        let xml = (1...8).map { "<d p=\"1.25,\($0),25,16711680,0,0,user,0\">文字 &amp; 测试</d>" }.joined()

        let (total, comments) = try fixture.comments(xml)

        #expect(total == 8)
        #expect(comments.map(\.mode) == [1, 2, 3, 4, 5, 6])
        #expect(comments.allSatisfy { $0.time == 1.25 && $0.fontSize == 25 && $0.color == 0xFF0000 })
        #expect(comments.allSatisfy { $0.text == "文字 & 测试" })
    }

    @Test func invalidAttributesAreCountedAndDropped() throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        let invalid = ["bad", "-1,1,25,0", "nan,1,25,0", "inf,1,25,0", "0,0,25,0",
                       "0,9,25,0", "0,1,0,0", "0,1,nan,0", "0,1,25,-1", "0,1,25,16777216"]
        let xml = invalid.map { "<d p=\"\($0)\">测试</d>" }.joined() + "<d>缺少参数</d>"

        let (total, comments) = try fixture.comments(xml)

        #expect(total == invalid.count + 1)
        #expect(comments.isEmpty)
    }

    @Test func toleratesIllegalCharactersAndPreservesMultibyteChunkBoundaries() throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        var data = Data(("<i><!--" + String(repeating: "x", count: 32_730) + "--><d p=\"0,1,25,0\">中文😀").utf8)
        data.append(contentsOf: [0, 1, 11, 255])
        data.append(Data("结束</d></i>".utf8))
        try data.write(to: fixture.xml)
        var comments: [DanmakuComment] = []

        let total = try DanmakuXMLParser().parse(xml: fixture.xml) { comments.append($0) }

        #expect(total == 1)
        #expect(comments.first?.text == "中文😀�结束")
    }

    @Test func streamsLargeXMLAndRejectsOversizedComment() throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        let body = String(repeating: "<d p=\"0,1,25,0\">中文😀</d>", count: 10_000)
            + "<d p=\"0,1,25,0\">" + String(repeating: "x", count: 65_537) + "</d>"
            + "<d p=\"0,5,25,0\"><![CDATA[末尾 & < >]]></d>"
        try fixture.write("<i>" + body + "</i>")
        var count = 0
        var last = ""

        let total = try DanmakuXMLParser().parse(xml: fixture.xml) {
            count += 1
            last = $0.text
        }

        #expect(total == 10_002)
        #expect(count == 10_001)
        #expect(last == "末尾 & < >")
    }

    @Test(arguments: ["<i><d p=\"0,1,25,0\">未结束", "<i><d></i>", "garbage",
                       "<!DOCTYPE i [<!ENTITY bomb '文字'>]><i><d p=\"0,1,25,0\">&bomb;</d></i>"])
    func malformedXMLThrows(xml: String) throws {
        let fixture = try DanmakuTestFixture()
        defer { fixture.cleanup() }
        try fixture.write(xml)

        #expect(throws: (any Error).self) {
            try DanmakuXMLParser().parse(xml: fixture.xml) { _ in }
        }
    }
}

import Foundation
import Testing
@testable import MuleeCore

struct DanmakuASSWriterTests {
    @Test(arguments: [(UInt32(0x123456), "&H563412&"), (UInt32(0xFF0000), "&H0000FF&"),
                       (UInt32(0), "&H000000&"), (UInt32(0xFFFFFF), "&HFFFFFF&")])
    func colorsUseBGR(rgb: UInt32, expected: String) {
        #expect(DanmakuASSWriter.assColor(rgb) == expected)
    }

    @Test func escapingPreventsOverrideAndNewlineInjection() {
        let escaped = DanmakuASSWriter.escape("{\\pos(0,0)}\\N\\h\r\n第二行\r末行")

        #expect(escaped == "\\{\\\u{200B}pos(0,0)\\}\\\u{200B}N\\\u{200B}h\\N第二行\\N末行")
        #expect(!escaped.contains("{\\pos"))
        #expect(!escaped.contains("\n"))
    }

    @Test func positionsDurationsSizeOpacityAndDarkOutline() throws {
        var writer = DanmakuASSWriter(videoSize: CGSize(width: 1280, height: 720))
        let rollingValue = writer.dialogue(for: DanmakuComment(
            time: 1.25, mode: 1, fontSize: 25, color: 0x111111, text: "滚动"
        ))
        let topValue = writer.dialogue(for: DanmakuComment(
            time: 10, mode: 5, fontSize: 25, color: 0xFFFFFF, text: "顶部"
        ))
        let bottomValue = writer.dialogue(for: DanmakuComment(
            time: 16, mode: 4, fontSize: 25, color: 0xFFFFFF, text: "底部"
        ))
        let reverseValue = writer.dialogue(for: DanmakuComment(
            time: 22, mode: 6, fontSize: 25, color: 0xFFFFFF, text: "逆向"
        ))
        let rolling = try #require(rollingValue)
        let top = try #require(topValue)
        let bottom = try #require(bottomValue)
        let reverse = try #require(reverseValue)

        #expect(writer.header.contains("PlayResX: 1280"))
        #expect(writer.header.contains("PlayResY: 720"))
        #expect(writer.header.contains("PingFang SC"))
        #expect(rolling.contains("0:00:01.25,0:00:09.25"))
        #expect(rolling.contains("\\move(1284,"))
        #expect(rolling.contains("\\fs31"))
        #expect(rolling.contains("\\3c&HFFFFFF&"))
        #expect(rolling.contains("\\alpha&H33&"))
        #expect(top.contains("0:00:10.00,0:00:15.00"))
        #expect(top.contains("\\pos(640,4)"))
        #expect(bottom.contains("\\pos(640,672)"))
        #expect(reverse.contains("\\move(-"))
    }

    @Test func simultaneousMixedModesNeverShareVerticalSpaceAndOverflowIsDropped() throws {
        var writer = DanmakuASSWriter()
        var positions: [Int] = []
        var dropped = 0
        for index in 0..<1000 {
            let comment = DanmakuComment(time: 0, mode: index % 6 + 1, fontSize: 25,
                                         color: 0xFFFFFF, text: "同时出现的测试弹幕")
            if let dialogue = writer.dialogue(for: comment) {
                let regex = try NSRegularExpression(pattern: #"\\(?:pos|move)\(-?\d+,(\d+)"#)
                let range = NSRange(dialogue.startIndex..., in: dialogue)
                let match = try #require(regex.firstMatch(in: dialogue, range: range))
                let yRange = try #require(Range(match.range(at: 1), in: dialogue))
                positions.append(try #require(Int(dialogue[yRange])))
            } else { dropped += 1 }
        }

        #expect(positions.count > 5)
        #expect(dropped > 980)
        let sorted = positions.sorted()
        for index in 1..<sorted.count { #expect(sorted[index] - sorted[index - 1] >= 70) }
    }

    @Test func tracksStayReservedUntilEndAndCanThenBeReused() throws {
        var writer = DanmakuASSWriter(videoSize: CGSize(width: 200, height: 50))
        let first = DanmakuComment(time: 0, mode: 1, fontSize: 250, color: 0, text: "短")
        let chasing = DanmakuComment(time: 7.99, mode: 6, fontSize: 250, color: 0,
                                     text: "更长的逆向弹幕不能追尾或者穿过前一条")
        let next = DanmakuComment(time: 8, mode: 5, fontSize: 250, color: 0, text: "复用")

        #expect(writer.dialogue(for: first) != nil)
        #expect(writer.dialogue(for: chasing) == nil)
        #expect(writer.dialogue(for: next) != nil)
    }

    @Test func multilineAndLargerFontsReserveMultipleRows() throws {
        var writer = DanmakuASSWriter(videoSize: CGSize(width: 640, height: 120))
        let multiline = DanmakuComment(time: 0, mode: 5, fontSize: 100, color: 0, text: "上行\n下行")
        let next = DanmakuComment(time: 0, mode: 1, fontSize: 100, color: 0, text: "其他")

        let value = writer.dialogue(for: multiline)
        let line = try #require(value)

        #expect(line.contains("上行\\N下行"))
        #expect(writer.dialogue(for: next) != nil)
        #expect(writer.dialogue(for: multiline) == nil)
    }
}

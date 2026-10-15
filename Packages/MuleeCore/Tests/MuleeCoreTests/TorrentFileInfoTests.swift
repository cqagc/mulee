import Foundation
import Testing
@testable import MuleeCore

@Suite struct TorrentFileInfoTests {
    @Test("单文件种子用原始 info 字节计算 SHA-1")
    func singleFile() throws {
        // 刻意让字典键不按序排列，重新编码后得到的 hash 会不同。
        let data = Data("d4:infod4:name10:Ubuntu.txt6:lengthi6eee".utf8)
        let info = try TorrentFileInfo.parse(data: data)
        #expect(info.name == "Ubuntu.txt")
        #expect(info.infoHash == "ae1b1056b4b1dd1e35e23c675a2f50686b33bf02")
        #expect(info.totalSize == 6)
        #expect(!info.isPrivate)
        #expect(info.files == [TorrentFileEntry(index: 0, path: "Ubuntu.txt", size: 6)])
    }

    @Test("多文件、中文 UTF-8 路径优先和 private")
    func multipleFiles() throws {
        let first = Data("d6:lengthi3e4:pathl".utf8) + TorrentFixtures.string("fallback.txt")
            + Data("e10:path.utf-8l".utf8) + TorrentFixtures.string("中文") + TorrentFixtures.string("说明.txt") + Data("ee".utf8)
        let second = Data("d6:lengthi4e4:pathl".utf8) + TorrentFixtures.string("Debian.txt") + Data("ee".utf8)
        let data = Data("d4:infod5:filesl".utf8) + first + second + Data("e4:name".utf8)
            + TorrentFixtures.string("fallback") + Data("10:name.utf-8".utf8) + TorrentFixtures.string("开源资料")
            + Data("7:privatei1eee".utf8)
        let info = try TorrentFileInfo.parse(data: data)
        #expect(info.name == "开源资料")
        #expect(info.isPrivate)
        #expect(info.totalSize == 7)
        #expect(info.files.map(\.path) == ["开源资料/中文/说明.txt", "开源资料/Debian.txt"])
        #expect(info.files.map(\.size) == [3, 4])
    }

    @Test("无效 UTF-8 使用替换字符")
    func invalidUTF8() throws {
        let data = Data("d4:infod5:filesld6:lengthi1e4:pathl1:".utf8) + Data([0xff])
            + Data("eee4:name1:Uee".utf8)
        let info = try TorrentFileInfo.parse(data: data)
        #expect(info.files.first?.path == "U/�")
    }

    @Test("恶意或损坏 Bencode 防御", arguments: [
        "", "d", "d4:info", "d4:infod4:name1:U6:lengthi1e", "d4:infod4:name-1:Uee",
        "d4:infod4:name999999999999999999999999:Uee", "d4:infod4:name4:Uee",
        "d4:infod4:name1:U6:lengthi9223372036854775808eee",
        "d4:infod4:name1:U6:lengthi-1eee", "d4:infod4:name1:U6:lengthi01eee",
        "d4:infod4:name1:U6:lengthi-0eee", "d4:infod4:name1:U6:lengthi+1eee",
        "d4:infod4:name1:U6:lengthi1eeeEXTRA", "d4:infod4:name1:U4:name1:V6:lengthi1eee"
    ])
    func malformed(_ text: String) {
        #expect(throws: EngineError.self) { try TorrentFileInfo.parse(data: Data(text.utf8)) }
    }

    @Test("超深嵌套、超大输入和总大小溢出")
    func limits() {
        let deep = "d1:x" + String(repeating: "l", count: 1000) + String(repeating: "e", count: 1001)
        #expect(throws: EngineError.self) { try TorrentFileInfo.parse(data: Data(deep.utf8)) }
        #expect(throws: EngineError.self) {
            try TorrentFileInfo.parse(data: Data(repeating: 100, count: BencodeParser.maximumLength + 1))
        }
        let overflow = "d4:infod5:filesld6:lengthi9223372036854775807e4:pathl1:aee"
            + "d6:lengthi1e4:pathl1:beee4:name1:Uee"
        #expect(throws: EngineError.self) { try TorrentFileInfo.parse(data: Data(overflow.utf8)) }
    }
}

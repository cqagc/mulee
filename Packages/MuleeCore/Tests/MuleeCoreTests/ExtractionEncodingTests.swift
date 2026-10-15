import Foundation
import Testing
@testable import MuleeCore

struct ExtractionEncodingTests {
    @Test("GBK 简体、Big5 繁体、Shift-JIS 日文纯函数评分")
    func scoring() {
        let simplified = ["星云传说/简体资料说明书.txt", "测试压缩下载.txt"]
        let traditional = ["星雲傳說/繁體資料說明書.txt", "測試壓縮下載.txt"]
        let japanese = ["星のたび/はじめに.txt", "サンプルデータ.txt"]
        #expect(FilenameEncodingDetector.score(filenames: simplified, encoding: .gbk) > FilenameEncodingDetector.score(filenames: simplified, encoding: .big5))
        #expect(FilenameEncodingDetector.score(filenames: traditional, encoding: .big5) > FilenameEncodingDetector.score(filenames: traditional, encoding: .gbk))
        #expect(FilenameEncodingDetector.score(filenames: japanese, encoding: .shiftJIS) > FilenameEncodingDetector.score(filenames: japanese, encoding: .gbk))
        #expect(FilenameEncodingDetector.score(filenames: ["資料.txt"], encoding: .big5) > FilenameEncodingDetector.score(filenames: ["�\0.txt"], encoding: .big5))
    }

    @Test("百分比输出包括退格、跨块片段与非法百分比")
    func progress() {
        #expect(SevenZipProcess.percentages(in: " 0%\u{8} 12%\r100% 200%") == [0, 0.12, 1])
    }

    @Test(arguments: ["../outside", "/absolute", "C:\\outside", "dir/../../escape", "dir\\..\\escape", "a\0b"])
    func unsafePaths(_ path: String) {
        #expect(throws: ExtractionFailure.unsafePath) { try ArchivePathSafety.validate(path: path) }
    }

    @Test("中文原因与缺卷等待分类")
    func failures() {
        #expect(ArchiveExtractor.classify("Unexpected end of archive", multipart: true) == .missingVolumes([]))
        #expect(ArchiveExtractor.classify("Unexpected end of archive", multipart: false) == .damagedArchive)
        #expect(ArchiveExtractor.classify("No space left on device", multipart: false) == .insufficientSpace)
        #expect(ExtractionFailure.wrongPasswords.localizedDescription == String(localized: "密码都不对", bundle: .module))
        #expect(ExtractionOptions().postAction == .trash)
        #expect(!ExtractionOptions().recursivelyExtract)
    }
}

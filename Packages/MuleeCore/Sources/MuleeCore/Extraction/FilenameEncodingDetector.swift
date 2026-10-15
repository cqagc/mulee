import CoreFoundation
import Foundation

public enum FilenameEncodingDetector {
    /// 启发式评分不是语言识别保证；界面仍可指定编码覆盖结果。
    public static func score(filenames: [String], encoding: ArchiveFilenameEncoding) -> Double {
        let common = Set("的一是在不了有和人這中大為上個國我以要他時來用們生到作地於出就分對成會可主發年動同工也能下過子說產種面而方後多定行學法所民得經之進著等部度家電力裡如水化高自二理起小物現實加量都兩體制機當使點從業本去把性好應開它合還因由其些然前外天政四日那社義事平形相全表間樣與關各重新線內數正心反你明看原又麼利比或但質氣第向道命變條結解問意建月公無系軍很情者最立代想已通並提直題程展果料象員位入常文總次品式活設及管特件長求老頭基資邊流路級少圖山統接知較將組見計別她手角期根論運指區強放決西被做必戰先回任取據處世車光圖標檔雲傳統遊戲說明測試資料繁體簡體東門書龍風聲萬舊臺灣寶劍夢錄讀網關聯與漢語下載壓縮名稱資源星空之旅")
        let simplified = Set("这为个国时来们于对会发动说产种后学现实体制机当点从业应开还义样与关线内数么质气变条结问无军题员总设长头资边级图统较将组见计论运区强决战据处车标档云传统游戏说明测试资料简东门书龙风声万旧台湾宝剑梦录读网联汉语下载压缩名称资源")
        let traditional = Set("這為個國時來們於對會發動說產種後學現實體機當點從業應開還義樣與關線內數麼質氣變條結問無軍題員總設長頭資邊級圖統較將組見計論運區強決戰據處車標檔雲傳統遊戲說明測試資料繁東門書龍風聲萬舊臺灣寶劍夢錄讀網聯漢語下載壓縮名稱資源")
        var result = 0.0
        for name in filenames {
            for character in name {
                let scalars = character.unicodeScalars
                if character == "�" { result -= 100; continue }
                if scalars.contains(where: { $0.value < 32 || (0x7f...0x9f).contains($0.value) }) {
                    result -= 50
                    continue
                }
                guard let scalar = scalars.first else { continue }
                if scalar.isASCII { continue }
                if common.contains(character) || simplified.contains(character) { result += 4 }
                else if (0x4e00...0x9fff).contains(scalar.value) { result += 0.1 }
                else { result -= 1 }
                if encoding == .gbk {
                    if simplified.contains(character) { result += 4 }
                    if traditional.contains(character) { result -= 1 }
                }
                if encoding == .big5 {
                    if traditional.contains(character) { result += 4 }
                    if simplified.contains(character) { result -= 1 }
                }
                if (0x3040...0x30ff).contains(scalar.value) {
                    result += encoding == .shiftJIS ? 7 : -2
                }
                if (0xff61...0xff9f).contains(scalar.value) { result -= 3 }
                if (0xe000...0xf8ff).contains(scalar.value) { result -= 20 }
            }
        }
        return result
    }

    public static func detect(archive: URL, binary: URL, password: String? = nil) async throws -> ArchiveFilenameEncoding {
        guard archive.pathExtension.lowercased() == "zip" else { return .utf8 }
        let entries = try ZipFilenameDirectory.read(archive)
        if !entries.isEmpty && entries.allSatisfy({ $0.isUTF8 || $0.unicodePath != nil }) { return .utf8 }
        var best = ArchiveFilenameEncoding.gbk
        var bestScore = -Double.infinity
        for encoding in [ArchiveFilenameEncoding.gbk, .big5, .shiftJIS] {
            guard let page = encoding.codePage else { continue }
            let listing = try await SevenZipProcess.run(
                binary: binary, arguments: ["l", "-slt", "-ba", "-sccUTF-8", "-mcp=\(page)", "--", archive.path], password: password
            )
            guard listing.status == 0 else { continue }
            let listedNames = listing.text.components(separatedBy: "\n").filter { $0.hasPrefix("Path = ") }.map { String($0.dropFirst(7)) }
            // macOS 26.04 接受 -mcp，但对这些代码页可能仍输出相同乱码。
            // 有中央目录时按原始字节评分；7zz 列表用于校验最终名称映射。
            let decodedNames = entries.map { entry in
                entry.unicodePath ?? (entry.isUTF8 ? String(data: entry.bytes, encoding: .utf8) : decode(entry.bytes, encoding: encoding)) ?? "�"
            }
            let value = score(filenames: entries.isEmpty ? listedNames : decodedNames, encoding: encoding)
            if value > bestScore { best = encoding; bestScore = value }
        }
        guard bestScore > -Double.infinity else { throw ExtractionFailure.damagedArchive }
        return best
    }

    static func decode(_ bytes: Data, encoding: ArchiveFilenameEncoding) -> String? {
        let cfEncoding: CFStringEncoding
        switch encoding {
        case .gbk: cfEncoding = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        case .big5: cfEncoding = CFStringEncoding(CFStringEncodings.big5.rawValue)
        case .shiftJIS: cfEncoding = CFStringEncoding(CFStringEncodings.shiftJIS.rawValue)
        case .utf8, .automatic: return String(data: bytes, encoding: .utf8)
        }
        return String(data: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)))
    }
}

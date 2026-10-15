import CoreFoundation
import Foundation
import Testing
@testable import MuleeCore

@Suite struct SettingsArchiveCommentTests {
    @Test func sharesPagePasswordRulesAndLimitsParsingToArchiveComment() {
        #expect(PasswordTextParser.password(in: "解压密码：fictional-secret；说明") == "fictional-secret")
        #expect(PasswordTextParser.password(in: "PASSWORD: abc123") == "abc123")
        #expect(PasswordTextParser.password(in: "密码：测试") == "测试")
        #expect(PasswordTextParser.password(in: "普通文字") == nil)
        #expect(ArchiveCommentReader.comment(in: "Type = zip\nComment = 说明\n密码：fictional\n\n----------\nPath = password:wrong") == "说明\n密码：fictional")
        #expect(ArchiveCommentReader.comment(in: "Comment = 说明\n\npassword: fictional\n\n----------") == "说明\n\npassword: fictional")
        #expect(ArchiveCommentReader.comment(in: "Type = 7z\n----------\nPath = password:wrong") == nil)
    }

    @Test(arguments: [ArchiveFilenameEncoding.gbk, .big5])
    func decodesLegacyComment(_ encoding: ArchiveFilenameEncoding) throws {
        let text = encoding == .gbk ? "下载说明 解压密码：fictional-secret" : "下載說明 密码：fictional-secret"
        let cf = encoding == .gbk ? CFStringEncodings.GB_18030_2000 : .big5
        let stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))
        // Big5 cannot represent the simplified 密码 label; English is shared by both.
        let input = encoding == .big5 ? "下載說明 password: fictional-secret" : text
        let bytes = try #require(input.data(using: stringEncoding))
        #expect(PasswordTextParser.password(in: ArchiveCommentReader.decode(bytes)) == "fictional-secret")
    }

    @Test(.enabled(if: ExtractionFixture.binary != nil, "需要 MULEE_7ZZ"), arguments: [ArchiveFilenameEncoding.utf8, .gbk, .big5])
    func realEncryptedZipComment(_ encoding: ArchiveFilenameEncoding) async throws {
        try await ExtractionFixture.withFixture { fixture in
            _ = try fixture.file("fictional.txt", data: Data("open source fixture".utf8))
            try await fixture.run(["a", "comment.zip", "fictional.txt", "-pfictional-secret", "-mem=AES256"])
            let archive = fixture.root.appendingPathComponent("comment.zip")
            var bytes = try Data(contentsOf: archive)
            let stringEncoding: String.Encoding
            switch encoding {
            case .gbk:
                stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
            case .big5:
                stringEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
            default:
                stringEncoding = .utf8
            }
            let commentText: String
            switch encoding {
            case .gbk: commentText = "下载说明 解压密码：fictional-secret"
            case .big5: commentText = "下載說明 password: fictional-secret"
            default: commentText = "解压密码：fictional-secret"
            }
            let comment = try #require(commentText.data(using: stringEncoding))
            // 7zz writes an empty EOCD comment; append without changing encrypted payload or its CRC.
            #expect(bytes.suffix(2) == Data([0, 0]))
            bytes[bytes.count - 2] = UInt8(comment.count & 255)
            bytes[bytes.count - 1] = UInt8(comment.count >> 8)
            bytes.append(comment)
            try bytes.write(to: archive)
            let binary = try #require(ExtractionFixture.binary)
            let listing = try await SevenZipProcess.run(binary: binary, arguments: ["l", "-slt", "--", archive.path])
            #expect(ArchiveCommentReader.comment(in: listing.text) != nil)
            let extractor = ArchiveExtractor(binary: binary, passwords: InMemoryPasswordProvider(passwords: ["rule": "wrong"]))
            let disabled = await extractor.extract(archive: archive, destination: fixture.destination, options: ExtractionOptions(postAction: .keep))
            #expect(disabled.failure == .wrongPasswords)
            let enabled = await extractor.extract(
                archive: archive, destination: fixture.destination, rules: [fixture.rule()],
                options: ExtractionOptions(readArchiveComment: true, pagePasswords: ["also-wrong"], postAction: .keep)
            )
            #expect(enabled.status == .succeeded)
            #expect(enabled.passwordSource == .archiveComment)
            #expect(enabled.matchedRule == nil)
            #expect(try String(contentsOf: fixture.destination.appendingPathComponent("fictional.txt"), encoding: .utf8) == "open source fixture")
        }
    }

    @Test(.enabled(if: ExtractionFixture.binary != nil, "需要 MULEE_7ZZ"))
    func ruleThenPageThenBookPriorityWithRealSevenZip() async throws {
        try await ExtractionFixture.withFixture { fixture in
            _ = try fixture.file("fictional.txt")
            try await fixture.run(["a", "secret.7z", "fictional.txt", "-pfictional-secret", "-mhe=on"])
            let archive = fixture.root.appendingPathComponent("secret.7z")
            let rule = fixture.rule()
            let book = fixture.rule(.passwordBook, id: nil)
            let options = ExtractionOptions(readArchiveComment: true, pagePasswords: ["fictional-secret"], postAction: .keep)
            let correctRule = ArchiveExtractor(passwords: InMemoryPasswordProvider(passwords: ["rule": "fictional-secret"], passwordBook: ["fictional-secret"]))
            let first = await correctRule.extract(archive: archive, destination: fixture.destination, rules: [rule, book], options: options)
            #expect(first.passwordSource == .keychainItem("rule"))
            let wrongRule = ArchiveExtractor(passwords: InMemoryPasswordProvider(passwords: ["rule": "wrong"], passwordBook: ["fictional-secret"]))
            let second = await wrongRule.extract(archive: archive, destination: fixture.destination, rules: [rule, book], options: options)
            #expect(second.passwordSource == .pageText)
            let third = await wrongRule.extract(archive: archive, destination: fixture.destination, rules: [rule, book], options: ExtractionOptions(postAction: .keep))
            #expect(third.passwordSource == .passwordBook)
            #expect(third.status == .succeeded)
        }
    }
}

import CoreFoundation
import Foundation
import Synchronization
import Testing
@testable import MuleeCore

@Suite(.serialized, .enabled(if: ExtractionFixture.binary != nil, "未设置可执行的 MULEE_7ZZ，跳过集成测试"))
struct ExtractionIntegrationTests {
    @Test("加密文件头规则密码解压，保留原件、碰撞自动编号、进度完成")
    func encryptedHeaders() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let original = try fixture.file("星雲資料.txt")
            try await fixture.run(["a", "secret.7z", original.lastPathComponent, "-pfictional-secret", "-mhe=on"])
            let archive = fixture.root.appendingPathComponent("secret.7z")
            try FileManager.default.createDirectory(at: fixture.destination, withIntermediateDirectories: true)
            let collision = fixture.destination.appendingPathComponent(original.lastPathComponent)
            try Data("existing".utf8).write(to: collision)
            let values = Mutex<[Double]>([])
            let extractor = ArchiveExtractor(passwords: InMemoryPasswordProvider(passwords: ["rule": "fictional-secret"]))
            let rule = fixture.rule()
            let result = await extractor.extract(archive: archive, destination: fixture.destination, rules: [rule], options: ExtractionOptions(postAction: .keep)) {
                value in values.withLock { $0.append(value) }
            }
            #expect(result.status == .succeeded)
            #expect(result.matchedRule == rule)
            #expect(result.passwordSource == .keychainItem("rule"))
            #expect(result.topLevelItems.map(\.lastPathComponent) == ["星雲資料 (2).txt"])
            let item = try #require(result.topLevelItems.first)
            #expect(try Data(contentsOf: item) == Data(contentsOf: original))
            #expect(try String(contentsOf: collision, encoding: .utf8) == "existing")
            #expect(FileManager.default.fileExists(atPath: archive.path))
            #expect(values.withLock { $0.first } == 0)
            #expect(values.withLock { $0.last } == 1)
        }
    }

    @Test("密码本依次尝试；全错保留原件，规则密码错误可回退密码本")
    func passwordBookAndFailure() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let file = try fixture.file("fictional.txt")
            try await fixture.run(["a", "secret.7z", file.lastPathComponent, "-pfictional-secret", "-mhe=on"])
            let archive = fixture.root.appendingPathComponent("secret.7z")
            let bytes = try Data(contentsOf: archive)
            let book = fixture.rule(.passwordBook, pattern: "常用密码", id: nil)
            let good = ArchiveExtractor(passwords: InMemoryPasswordProvider(passwordBook: ["wrong", "fictional-secret"]))
            let success = await good.extract(archive: archive, destination: fixture.destination, rules: [book], options: ExtractionOptions(postAction: .keep))
            #expect(success.status == .succeeded)
            #expect(success.matchedRule == book)
            #expect(success.passwordSource == .passwordBook)
            let bad = ArchiveExtractor(passwords: InMemoryPasswordProvider(passwords: ["rule": "wrong"], passwordBook: ["fictional-secret"]))
            let failure = await bad.extract(archive: archive, destination: fixture.root.appendingPathComponent("bad"), rules: [fixture.rule(), book], options: ExtractionOptions(postAction: .keep))
            #expect(failure.status == .succeeded)
            #expect(failure.passwordSource == .passwordBook)
            #expect(try Data(contentsOf: archive) == bytes)
            #expect(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("bad").path))
            let badBook = ArchiveExtractor(passwords: InMemoryPasswordProvider(passwordBook: ["bad", "also-bad"]))
            let allWrong = await badBook.extract(archive: archive, destination: fixture.destination, rules: [book])
            #expect(allWrong.failure == .wrongPasswords)
            #expect(try Data(contentsOf: archive) == bytes)
        }
    }

    @Test("真实分卷：缺中间卷或末卷均等待，全部到齐后删除所有原卷")
    func volumes() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let payload = Data((0..<4096).map { _ in UInt8.random(in: 0...255) })
            let file = try fixture.file("fictional.bin", data: payload)
            try await fixture.run(["a", "split.7z", file.lastPathComponent, "-v1024b", "-mx=0"])
            let names = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).filter { $0.hasPrefix("split.7z.") }.sorted()
            #expect(names.count > 2)
            let main = fixture.root.appendingPathComponent(try #require(names.first))
            let last = fixture.root.appendingPathComponent(try #require(names.last))
            let saved = try Data(contentsOf: last)
            try FileManager.default.removeItem(at: last)
            let extractor = ArchiveExtractor()
            let explicit = await extractor.extract(archive: main, destination: fixture.destination, options: ExtractionOptions(expectedVolumeNames: names))
            #expect(explicit.status == .waitingForVolumes)
            #expect(explicit.failure == .missingVolumes([last.lastPathComponent]))
            let unknown = await extractor.extract(archive: main, destination: fixture.destination)
            #expect(unknown.status == .waitingForVolumes)
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            #expect(FileManager.default.fileExists(atPath: main.path))
            try saved.write(to: last)
            let success = await extractor.extract(archive: last, destination: fixture.destination,
                                                  options: ExtractionOptions(postAction: .delete, expectedVolumeNames: names))
            #expect(success.status == .succeeded)
            #expect(success.originalVolumes.count == names.count)
            #expect(try Data(contentsOf: fixture.destination.appendingPathComponent("fictional.bin")) == payload)
            for name in names { #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path)) }
        }
    }

    @Test("真实无 UTF-8 标记 ZIP 自动区分 Big5、GBK、Shift-JIS", arguments: [ArchiveFilenameEncoding.big5, .gbk, .shiftJIS])
    func legacyEncoding(_ encoding: ArchiveFilenameEncoding) async throws {
        try await ExtractionFixture.withFixture { fixture in
            let name: String
            let cf: CFStringEncodings
            switch encoding {
            case .big5: name = "星雲傳說_繁體資料說明書.txt"; cf = .big5
            case .gbk: name = "星云传说_简体资料说明书.txt"; cf = .GB_18030_2000
            default: name = "星のたび_はじめに_データ.txt"; cf = .shiftJIS
            }
            let raw = try #require(name.data(using: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(cf.rawValue)))))
            let archive = try fixture.zip(rawName: raw)
            let metadata = try ZipFilenameDirectory.read(archive)
            #expect(metadata.count == 1)
            #expect(metadata.first?.isUTF8 == false)
            let extractor = ArchiveExtractor()
            let result = await extractor.extract(archive: archive, destination: fixture.destination, options: ExtractionOptions(postAction: .keep))
            #expect(result.status == .succeeded)
            #expect(result.encoding == encoding)
            #expect(result.topLevelItems.map(\.lastPathComponent) == [name])
            #expect(try String(contentsOf: fixture.destination.appendingPathComponent(name), encoding: .utf8) == "fictional payload")
            let forced = await extractor.extract(archive: archive, destination: fixture.root.appendingPathComponent("forced"),
                                                options: ExtractionOptions(encoding: encoding, postAction: .keep))
            #expect(forced.status == .succeeded)
            #expect(forced.topLevelItems.map(\.lastPathComponent) == [name])
        }
    }

    @Test("UTF-8 标志与实际字节不符时按本地编码修复，不误报损坏")
    func mislabeledUTF8Flag() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let name = "星雲傳說_繁體資料說明書.txt"
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
            let raw = try #require(name.data(using: encoding))
            let archive = try fixture.zip("mislabeled.zip", rawName: raw)
            // 给本地头和中央目录都置上 0x800（UTF-8）标志，模拟打包工具写错标志。
            var bytes = try Data(contentsOf: archive)
            for index in 0..<(bytes.count - 10) {
                let signature = bytes[index..<index + 4]
                if signature == Data([0x50, 0x4b, 0x03, 0x04]) { bytes[index + 7] |= 0x08 }
                if signature == Data([0x50, 0x4b, 0x01, 0x02]) { bytes[index + 9] |= 0x08 }
            }
            try bytes.write(to: archive)
            #expect(try ZipFilenameDirectory.read(archive).first?.isUTF8 == false)
            let result = await ArchiveExtractor().extract(archive: archive, destination: fixture.destination, options: ExtractionOptions(postAction: .keep))
            #expect(result.status == .succeeded)
            #expect(result.encoding == .big5)
            #expect(result.topLevelItems.map(\.lastPathComponent) == [name])
        }
    }

    @Test("Big5 多层目录与目录条目一起修复，Unicode Path 扩展优先")
    func directoriesAndUnicodeExtra() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue)))
            let directoryName = "星雲資料/繁體說明/"
            let filename = directoryName + "測試文字.txt"
            let directory = try #require(directoryName.data(using: encoding))
            let name = try #require(filename.data(using: encoding))
            let archive = try fixture.zipEntries("directories.zip", entries: [
                (directory, Data(), 0x41ed0010, nil),
                (name, Data("nested payload".utf8), 0, nil)
            ])
            let result = await ArchiveExtractor().extract(archive: archive, destination: fixture.destination, options: ExtractionOptions(postAction: .keep))
            #expect(result.status == .succeeded)
            #expect(result.encoding == .big5)
            #expect(result.warnings.isEmpty)
            #expect(result.topLevelItems.map(\.lastPathComponent) == ["星雲資料"])
            #expect(try String(contentsOf: fixture.destination.appendingPathComponent(filename), encoding: .utf8) == "nested payload")
            let unicodeName = "星雲資料_擴展欄位.txt"
            let withExtra = try fixture.zip("unicode.zip", rawName: Data("legacy-name.txt".utf8), unicodePath: unicodeName)
            let unicode = await ArchiveExtractor().extract(archive: withExtra, destination: fixture.destination, options: ExtractionOptions(postAction: .keep))
            #expect(unicode.status == .succeeded)
            #expect(unicode.encoding == .utf8)
            #expect(unicode.topLevelItems.map(\.lastPathComponent) == [unicodeName])
        }
    }

    @Test("CRC 或条目数量对不上时整批保留原名，不做部分修复")
    func repairMismatch() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let archive = try fixture.zip(rawName: Data("original.txt".utf8))
            let raw = fixture.root.appendingPathComponent("raw", isDirectory: true)
            try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: false)
            let untouched = raw.appendingPathComponent("garbled.txt")
            let payload = Data("fictional payload".utf8)
            try payload.write(to: untouched)
            let mismatch = "Path = garbled.txt\nSize = \(payload.count)\nCRC = 00000000\n"
            let (directory, repaired) = try ZipFilenameRepair.repair(archive: archive, rawRoot: raw, listing: mismatch, encoding: .big5)
            #expect(directory == raw)
            #expect(!repaired)
            #expect(try Data(contentsOf: untouched) == payload)
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("decoded").path))
            let (_, empty) = try ZipFilenameRepair.repair(archive: archive, rawRoot: raw, listing: "", encoding: .big5)
            #expect(!empty)
        }
    }

    @Test("拒绝 ZIP 路径穿越和绝对路径，原件及目录外不变", arguments: ["../escape.txt", "/fictional-escape.txt", "safe/../../escape.txt", "C:\\escape.txt"])
    func traversal(_ name: String) async throws {
        try await ExtractionFixture.withFixture { fixture in
            let archive = try fixture.zip(rawName: Data(name.utf8))
            let bytes = try Data(contentsOf: archive)
            let result = await ArchiveExtractor().extract(archive: archive, destination: fixture.destination)
            #expect(result.status == .failed)
            #expect(result.failure == .unsafePath)
            #expect(try Data(contentsOf: archive) == bytes)
            #expect(!FileManager.default.fileExists(atPath: fixture.destination.path))
            #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("escape.txt").path))
        }
    }

    @Test("拒绝 ZIP 和 7z 符号链接，避免通过链接向目录外写入")
    func symlinks() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let archive = try fixture.zip("link.zip", rawName: Data("link".utf8), content: Data("../outside".utf8), attributes: 0xa1ff0000)
            let zipResult = await ArchiveExtractor().extract(archive: archive, destination: fixture.destination)
            #expect(zipResult.failure == .unsafePath)
            let link = fixture.root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "../outside")
            try await fixture.run(["a", "link.7z", "link", "-snl"])
            let seven = fixture.root.appendingPathComponent("link.7z")
            let result = await ArchiveExtractor().extract(archive: seven, destination: fixture.destination)
            #expect(result.failure == .unsafePath)
            #expect(FileManager.default.fileExists(atPath: seven.path))
        }
    }

    @Test("损坏压缩包失败保留原件，取消任务不留子进程")
    func corruptAndCancel() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let broken = try fixture.file("broken.7z", data: Data("not an archive".utf8))
            let failed = await ArchiveExtractor().extract(archive: broken, destination: fixture.destination)
            #expect(failed.failure == .damagedArchive)
            #expect(FileManager.default.fileExists(atPath: broken.path))
            let task = Task {
                await ArchiveExtractor().extract(archive: broken, destination: fixture.destination)
            }
            task.cancel()
            #expect(await task.value.failure == .cancelled)
        }
    }

    @Test("运行中子进程取消与超时均被回收")
    func processLifecycle() async throws {
        let sleeper = URL(fileURLWithPath: "/bin/sleep")
        for _ in 0..<10 {
            await #expect(throws: ExtractionFailure.timedOut) {
                try await SevenZipProcess.run(binary: sleeper, arguments: ["30"], timeout: .milliseconds(40))
            }
            let task = Task {
                try await SevenZipProcess.run(binary: sleeper, arguments: ["30"])
            }
            try await Task.sleep(for: .milliseconds(40))
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
        let processes = try await SevenZipProcess.run(binary: URL(fileURLWithPath: "/bin/ps"), arguments: ["-axo", "ppid=,comm="])
        let remaining = processes.text.components(separatedBy: "\n").filter { line in
            let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, Int32(fields[0]) == ProcessInfo.processInfo.processIdentifier else { return false }
            return ["sleep", "7zz"].contains(URL(fileURLWithPath: String(fields[1])).lastPathComponent)
        }
        #expect(remaining.isEmpty)

    }

    @Test("成功原件移入系统废纸篓，失败结果调用后处理也不动原件")
    func trash() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let name = "Mulee-Fictional-" + UUID().uuidString + ".zip"
            let archive = try fixture.zip(name, rawName: Data("fictional.txt".utf8))
            let extractor = ArchiveExtractor()
            let result = await extractor.extract(archive: archive, destination: fixture.destination, options: ExtractionOptions(postAction: .keep))
            #expect(result.status == .succeeded)
            let trashed = try ExtractionPostAction.trash.apply(to: result)
            defer {
                for url in trashed {
                    do { try FileManager.default.removeItem(at: url) }
                    catch { Issue.record("测试废纸篓条目清理失败：\(error)") }
                }
            }
            #expect(!FileManager.default.fileExists(atPath: archive.path))
            #expect(trashed.count == 1)
            for url in trashed {
                #expect(url.pathComponents.contains(".Trash") || url.pathComponents.contains(".Trashes"))
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
            let wrong = try fixture.file("broken.7z", data: Data("broken".utf8))
            let failed = await extractor.extract(archive: wrong, destination: fixture.destination)
            #expect(try ExtractionPostAction.delete.apply(to: failed).isEmpty)
            #expect(FileManager.default.fileExists(atPath: wrong.path))
        }
    }

    @Test("递归默认关闭，开启最多三层，第四层压缩包保留")
    func recursion() async throws {
        try await ExtractionFixture.withFixture { fixture in
            _ = try fixture.file("fictional.txt")
            try await fixture.run(["a", "layer0.zip", "fictional.txt"])
            for index in 1...3 {
                try await fixture.run(["a", "layer\(index).zip", "layer\(index - 1).zip"])
            }
            let outer = fixture.root.appendingPathComponent("layer3.zip")
            let extractor = ArchiveExtractor()
            let disabled = await extractor.extract(archive: outer, destination: fixture.destination, options: ExtractionOptions(postAction: .keep))
            #expect(disabled.nestedResults.isEmpty)
            #expect(disabled.topLevelItems.map(\.lastPathComponent) == ["layer2.zip"])
            let recursiveDestination = fixture.root.appendingPathComponent("recursive")
            let recursive = await extractor.extract(archive: outer, destination: recursiveDestination,
                                                   options: ExtractionOptions(postAction: .keep, recursivelyExtract: true))
            #expect(recursive.status == .succeeded)
            #expect(recursive.nestedResults.count == 1)
            let second = try #require(recursive.nestedResults.first)
            #expect(second.status == .succeeded)
            let third = try #require(second.nestedResults.first)
            #expect(third.status == .succeeded)
            #expect(third.nestedResults.isEmpty)
            #expect(FileManager.default.fileExists(atPath: recursiveDestination.appendingPathComponent("layer0.zip").path))
            #expect(!FileManager.default.fileExists(atPath: recursiveDestination.appendingPathComponent("fictional.txt").path))
        }
    }
}

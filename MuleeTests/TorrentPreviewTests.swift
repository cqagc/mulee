import Foundation
import MuleeCore
import Testing

@MainActor
@Suite struct TorrentPreviewTests {
    @Test func singleFileMetadata() throws {
        let info = try parse(["name": "example.txt", "length": 4096], extra: ["created by": "ExampleTool"])
        let model = TorrentPreviewModel(info: info)

        #expect(model.name == "example.txt")
        #expect(model.totalSize == 4096)
        #expect(model.fileCount == 1)
        #expect(model.createdBy == "ExampleTool")
        #expect(model.version == "v1")
        #expect(model.isPrivate == false)
        #expect(model.trackerTiers.isEmpty)
        #expect(model.rows.count == 1)
        #expect(model.rows.first?.name == "example.txt")
        #expect(model.rows.first?.size == 4096)
        #expect(model.remainingFileCount == 0)
    }

    @Test(arguments: [0, 1])
    func privateFlagAndNestedTree(flag: Int) throws {
        let info = try parse([
            "name": "example", "private": flag,
            "files": [
                ["path": ["notes", "b.txt"], "length": 2],
                ["path": ["media", "sample.bin"], "length": 3],
                ["path": ["notes", "a.txt"], "length": 4]
            ]
        ])
        let model = TorrentPreviewModel(info: info)

        #expect(model.totalSize == 9)
        #expect(model.fileCount == 3)
        #expect(model.isPrivate == (flag == 1))
        #expect(model.createdBy == nil)
        #expect(model.rows.map(\.name) == ["media", "sample.bin", "notes", "a.txt", "b.txt"])
        #expect(model.rows.map(\.depth) == [0, 1, 0, 1, 1])
        #expect(model.rows.map(\.size) == [nil, 3, nil, 4, 2])
        #expect(Set(model.rows.map(\.id)).count == model.rows.count)
    }

    @Test func trackerTiersPreserveOrderAndStandaloneAnnounce() throws {
        let info = try parse(["name": "example", "length": 1], extra: [
            "announce": "https://primary.invalid/announce",
            "announce-list": [
                ["https://b.invalid/announce", "https://a.invalid/announce", "https://b.invalid/announce"],
                ["udp://c.invalid:80/announce"],
                []
            ]
        ])
        let model = TorrentPreviewModel(info: info)

        #expect(model.trackerTiers == [
            ["https://primary.invalid/announce"],
            ["https://b.invalid/announce", "https://a.invalid/announce"],
            ["udp://c.invalid:80/announce"]
        ])
        #expect(info.trackers == [
            "https://a.invalid/announce", "https://b.invalid/announce",
            "https://primary.invalid/announce", "udp://c.invalid:80/announce"
        ])
    }

    @Test func announceAlreadyInTierIsNotRepeated() throws {
        let tracker = "https://tracker.invalid/announce"
        let info = try parse(["name": "example", "length": 0], extra: [
            "announce": tracker, "announce-list": [[tracker]]
        ])
        #expect(TorrentPreviewModel(info: info).trackerTiers == [[tracker]])
    }

    @Test(arguments: [499, 500, 501])
    func limitsFileRows(count: Int) throws {
        let files = (0..<count).map { ["path": ["file-\($0).txt"], "length": 1] as [String: Any] }
        let model = TorrentPreviewModel(info: try parse(["name": "example", "files": files]))

        #expect(model.fileCount == count)
        #expect(model.totalSize == Int64(count))
        #expect(model.rows.count == min(count, 500))
        #expect(model.remainingFileCount == max(0, count - 500))
    }

    @Test func directoriesAlsoCountTowardRowLimit() throws {
        let files = (0..<501).map { ["path": ["folder", "file-\($0).txt"], "length": 1] as [String: Any] }
        let model = TorrentPreviewModel(info: try parse(["name": "example", "files": files]))

        #expect(model.rows.count == 500)
        #expect(model.rows.first?.name == "folder")
        #expect(model.rows.first?.size == nil)
        #expect(model.rows.filter { $0.size != nil }.count == 499)
        #expect(model.remainingFileCount == 2)
    }

    @Test func v2FileTreeAndHybridVersion() throws {
        let tree: [String: Any] = [
            "folder": [
                "b.txt": ["": ["length": 7]],
                "a.txt": ["": ["length": 5]]
            ]
        ]
        let v2 = try parse(["name": "example", "meta version": 2, "file tree": tree])
        let model = TorrentPreviewModel(info: v2)
        #expect(v2.hasV1 == false)
        #expect(v2.hasV2)
        #expect(model.version == "v2")
        #expect(model.totalSize == 12)
        #expect(model.fileCount == 2)
        #expect(model.rows.map(\.name) == ["folder", "a.txt", "b.txt"])

        let hybrid = try parse([
            "name": "example", "length": 12, "pieces": Data(repeating: 0, count: 20),
            "meta version": 2, "file tree": tree
        ])
        #expect(hybrid.hasV1)
        #expect(hybrid.hasV2)
        #expect(TorrentPreviewModel(info: hybrid).version == "v1 / v2")
        #expect(hybrid.files.map(\.path) == ["example"])
    }

    @Test func v2SingleFileDoesNotRepeatName() throws {
        let info = try parse([
            "name": "example.txt", "meta version": 2,
            "file tree": ["example.txt": ["": ["length": 0]]]
        ])
        #expect(info.files.map(\.path) == ["example.txt"])
        #expect(TorrentPreviewModel(info: info).rows.first?.depth == 0)
    }

    @Test func malformedV2TreesAreRejected() {
        let trees: [[String: Any]] = [
            [:], ["": ["length": 1]], ["file": ["": ["length": -1]]],
            ["file": ["": ["length": 1], "child": ["": ["length": 1]]]],
            ["file": "invalid"]
        ]
        for tree in trees {
            #expect(throws: (any Error).self) {
                try parse(["name": "example", "meta version": 2, "file tree": tree])
            }
        }
    }

    @Test func v2RootedAndRootlessTreesKeepTheirPaths() throws {
        let rooted = try parse([
            "name": "example", "meta version": 2,
            "file tree": ["example": ["a.txt": ["": ["length": 1]], "b.txt": ["": ["length": 2]]]]
        ])
        #expect(rooted.files.map(\.path) == ["example/a.txt", "example/b.txt"])
        #expect(TorrentPreviewModel(info: rooted).rows.map(\.name) == ["a.txt", "b.txt"])

        let rootless = try parse([
            "name": "example", "meta version": 2,
            "file tree": ["example": ["a.txt": ["": ["length": 1]]], "b.txt": ["": ["length": 2]]]
        ])
        #expect(rootless.files.map(\.path) == ["b.txt", "example/a.txt"])
        #expect(TorrentPreviewModel(info: rootless).rows.map(\.name) == ["b.txt", "example", "a.txt"])
    }

    @Test func loadRejectsInvalidMissingAndNonFileInputs() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "invalid.torrent")
        try Data("invalid".utf8).write(to: file)

        #expect(throws: (any Error).self) { try TorrentPreviewModel.load(from: file) }
        #expect(throws: (any Error).self) { try TorrentPreviewModel.load(from: folder.appending(path: "missing")) }
        #expect(throws: TorrentPreviewError.unreadable) { try TorrentPreviewModel.load(from: folder) }
        #expect(throws: TorrentPreviewError.unreadable) {
            try TorrentPreviewModel.load(from: URL(string: "https://example.invalid/example.torrent")!)
        }
    }

    @Test func loadChecksTwentyMegabyteBoundary() throws {
        let folder = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "boundary.torrent")
        let base = encode(["info": ["name": "example", "length": 1], "padding": ""])
        let available = TorrentPreviewModel.maximumFileSize - base.count
        let paddingSize = available - (String(available).count - 1)
        let data = encode(["info": ["name": "example", "length": 1], "padding": String(repeating: "x", count: paddingSize)])
        #expect(data.count == TorrentPreviewModel.maximumFileSize)
        try data.write(to: file)
        #expect(try TorrentPreviewModel.load(from: file).name == "example")

        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(TorrentPreviewModel.maximumFileSize + 1))
        #expect(throws: TorrentPreviewError.tooLarge) { try TorrentPreviewModel.load(from: file) }
    }

    private func parse(_ info: [String: Any], extra: [String: Any] = [:]) throws -> TorrentFileInfo {
        var root = extra
        root["info"] = info
        return try TorrentFileInfo.parse(data: encode(root))
    }

    private func encode(_ value: Any) -> Data {
        if let bytes = value as? Data { return Data("\(bytes.count):".utf8) + bytes }
        if let text = value as? String { return encode(Data(text.utf8)) }
        if let number = value as? Int { return Data("i\(number)e".utf8) }
        if let list = value as? [Any] {
            return Data("l".utf8) + list.reduce(Data()) { $0 + encode($1) } + Data("e".utf8)
        }
        if let dictionary = value as? [String: Any] {
            return Data("d".utf8) + dictionary.keys.sorted().reduce(Data()) {
                $0 + encode($1) + encode(dictionary[$1]!)
            } + Data("e".utf8)
        }
        Issue.record("Unsupported fixture value")
        return Data()
    }

    private func temporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "Mulee-preview-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}

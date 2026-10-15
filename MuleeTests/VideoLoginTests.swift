import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct VideoLoginTests {
    private func payload(domain: String = ".bilibili.com", value: String = "synthetic") throws -> Data {
        let cookie = VideoCookie(domain: domain, path: "/", name: "SESSDATA", value: value,
                                 secure: true, httpOnly: true, hostOnly: false)
        return try JSONEncoder().encode(VideoCookieRequest(site: .bilibili, cookies: [cookie]))
    }

    @Test func validatesNativePayloadBeforeStorage() throws {
        #expect(try VideoCookieRequest.parse(payload()).site == .bilibili)
        for domain in [".youtube.com", ".evil.org", ".bilibili.com.evil.org"] {
            #expect(throws: (any Error).self) { try VideoCookieRequest.parse(payload(domain: domain)) }
        }
        for data in [Data("invalid".utf8), Data(#"{"type":"videoCookies","site":"other","cookies":[]}"#.utf8),
                     Data(repeating: 32, count: VideoCookieRequest.maximumBytes + 1),
                     Data(#"{"type":"videoCookies","site":"bilibili","cookies":[],"url":"mulee://add"}"#.utf8)] {
            #expect(throws: (any Error).self) { try VideoCookieRequest.parse(data) }
        }
        #expect(throws: (any Error).self) { try VideoCookieRequest.parse(payload(value: "synthetic\nforged")) }
    }

    @Test func chromeFrameAndManifestAreBoundToOneExtension() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let frame = root.appendingPathComponent("frame")
        let data = try payload()
        var length = UInt32(data.count).littleEndian
        var bytes = withUnsafeBytes(of: &length) { Data($0) }
        bytes.append(data)
        try bytes.write(to: frame)
        let input = try FileHandle(forReadingFrom: frame)
        defer { try? input.close() }
        #expect(try VideoNativeMessaging.readRequest(from: input).cookies.count == 1)
        try VideoNativeMessaging.install(executable: URL(filePath: "/usr/bin/true"), home: root)
        let file = root.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/" + VideoNativeMessaging.host + ".json")
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(object["allowed_origins"] as? [String] == [VideoNativeMessaging.origin])
        #expect(object["path"] as? String == "/usr/bin/true")
        #expect(VideoNativeMessaging.acceptsOrigin(["Mulee", VideoNativeMessaging.origin]))
        #expect(!VideoNativeMessaging.acceptsOrigin(["Mulee", "chrome-extension://other/"]))
        #expect(!VideoNativeMessaging.acceptsOrigin(["Mulee", VideoNativeMessaging.origin, "extra"]))
    }

    @Test func chromeManifestReadinessChecksCurrentExecutableAndOrigin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = URL(filePath: "/usr/bin/true")
        #expect(!VideoNativeMessaging.isInstalled(executable: executable, home: root))
        try VideoNativeMessaging.install(executable: executable, home: root)
        #expect(VideoNativeMessaging.isInstalled(executable: executable, home: root))
        #expect(!VideoNativeMessaging.isInstalled(executable: URL(filePath: "/usr/bin/false"), home: root))
        let file = root.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts/" + VideoNativeMessaging.host + ".json")
        let manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        for origins in [[], ["chrome-extension://other/"], [VideoNativeMessaging.origin, "chrome-extension://other/"]] {
            var changed = manifest
            changed["allowed_origins"] = origins
            try JSONSerialization.data(withJSONObject: changed).write(to: file)
            #expect(!VideoNativeMessaging.isInstalled(executable: executable, home: root))
        }
        try Data("invalid".utf8).write(to: file)
        #expect(!VideoNativeMessaging.isInstalled(executable: executable, home: root))
    }

    @Test func rejectsInvalidLoginWithoutReplacingSavedFallback() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VideoLoginStore(fallbackDirectory: root)
        let saved = try VideoCookieRequest.parse(payload())
        try await store.saveFallback(saved)
        let cookie = VideoCookie(domain: ".bilibili.com", path: "/", name: "test", value: "synthetic",
                                 secure: true, httpOnly: true, hostOnly: false)
        let requests = [VideoCookieRequest(site: .bilibili, cookies: []),
                        VideoCookieRequest(site: .youtube, cookies: []),
                        VideoCookieRequest(site: .bilibili, cookies: [cookie])]
        for request in requests {
            await #expect(throws: EngineError.self) { try await store.save(request) }
            await #expect(throws: EngineError.self) { try await store.saveFallback(request) }
        }
        #expect(try await store.loadFallback(.bilibili)?.cookies == saved.cookies)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("youtube.json").path))
    }

    @Test func legacyEmptyFallbackRemainsReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("bilibili.json")
        try JSONEncoder().encode(VideoCookieRequest(site: .bilibili, cookies: [])).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let store = VideoLoginStore(fallbackDirectory: root)
        #expect(try await store.loadFallback(.bilibili)?.cookies.isEmpty == true)
    }

    @Test func rejectsTruncatedAndOversizedFrames() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        for bytes in [Data([1, 0]), Data([0xff, 0xff, 0xff, 0x7f]), Data([2, 0, 0, 0, 123])] {
            try bytes.write(to: file)
            let input = try FileHandle(forReadingFrom: file)
            defer { try? input.close() }
            #expect(throws: (any Error).self) { try VideoNativeMessaging.readRequest(from: input) }
        }
    }

    @Test func unprovisionedFallbackIsPrivatePersistentAndClearable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = VideoLoginStore(fallbackDirectory: root)
        let request = try VideoCookieRequest.parse(payload())
        try await store.saveFallback(request)
        let reloaded = VideoLoginStore(fallbackDirectory: root)
        #expect(try await reloaded.loadFallback(.bilibili)?.cookies == request.cookies)
        let file = root.appendingPathComponent("bilibili.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        await #expect(throws: (any Error).self) { try await reloaded.loadFallback(.bilibili) }
        try await reloaded.removeFallback(.bilibili)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func partSelectionCreatesOnlySelectedIndependentTasks() async throws {
        let source = try #require(URL(string: "https://www.bilibili.com/video/BVexample?p=2"))
        let parts = try (1...3).map { index in
            YtDlpPlaylistEntry(index: index, title: "示例部分 \(index)",
                              url: try #require(URL(string: "https://www.bilibili.com/video/BVexample?p=\(index)")))
        }
        let draft = NewTaskModel(inputText: source.absoluteString)
        let item = try #require(draft.links.first)
        await item.loadVideoParts { _ in parts }
        #expect(item.selectedVideoParts == [parts[1].id])
        item.selectedVideoParts = []
        #expect(!draft.canStartDownload)
        item.selectedVideoParts = [parts[0].id, parts[2].id]
        let app = AppModel(tasks: [])
        draft.createTasks(in: app)
        #expect(app.tasks.map(\.sourceLink) == [parts[0].url.absoluteString, parts[2].url.absoluteString])
        #expect(app.tasks.map(\.name) == ["P1 示例部分 1", "P3 示例部分 3"])
    }
}

import Foundation
import Testing
@testable import MuleeCore

@Suite struct PublicTrackerSubscriptionTests {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @Test("只接受有效 UDP/HTTP/HTTPS，保留顺序并规范化去重")
    func parsing() throws {
        let text = """
            \u{FEFF}UDP://TRACKER.EXAMPLE.COM:1337/announce
            udp://tracker.example.com:1337/announce
            HTTPS://TRACKER.EXAMPLE.COM:443/announce?key=value
            https://tracker.example.com/announce?key=value
            http://tracker.example.com:80/announce
            ws://tracker.example.com/announce
            wss://tracker.example.com/announce
            ftp://tracker.example.com/announce
            file:///tracker
            https:///announce
            https://tracker.example.com:0/announce
            https://tracker.example.com:65536/announce
            https://user:password\u{40}tracker.example.com/announce
            https://tracker.example.com/has space
            https://tracker.example.com/announce#fragment
            # comment
            <html>not a tracker</html>
            """
        #expect(PublicTrackerList.parse(text) == [
            "udp://tracker.example.com:1337/announce",
            "https://tracker.example.com/announce?key=value",
            "http://tracker.example.com/announce"
        ])
        #expect(throws: PublicTrackerError.invalidResponse) { try PublicTrackerList.decode(Data([0xff])) }
        #expect(throws: PublicTrackerError.invalidResponse) { try PublicTrackerList.decode(Data("<html>error</html>".utf8)) }
        #expect(throws: PublicTrackerError.responseTooLarge) {
            try PublicTrackerList.decode(Data(repeating: 32, count: PublicTrackerList.maximumResponseSize + 1))
        }
        let many = (0..<2_010).map { "https://tracker\($0).example.com/announce" }.joined(separator: "\n")
        #expect(PublicTrackerList.parse(many).count == PublicTrackerList.maximumTrackers)
    }

    @Test("订阅分组、备用地址、去重与配置上限")
    func subscriptions() throws {
        let defaults = try PublicTrackerList.subscriptions(PublicTrackerList.defaultSubscriptions)
        #expect(defaults.count == 2)
        #expect(defaults.allSatisfy { $0.count >= 2 })
        #expect(try PublicTrackerList.subscriptions(" \n").isEmpty)
        let text = "https://example.com/list | https://mirror.example.com/list\nhttps://example.com/list"
        #expect(try PublicTrackerList.subscriptions(text).count == 1)
        for bad in ["udp://example.com/list", "https://example.com/list |", "https://user:pass@example.com/list", "not a URL"] {
            #expect(throws: PublicTrackerError.invalidSubscriptions) { try PublicTrackerList.subscriptions(bad) }
        }
        let many = (0..<33).map { "https://example.com/\($0)" }.joined(separator: "\n")
        #expect(throws: PublicTrackerError.invalidSubscriptions) { try PublicTrackerList.subscriptions(many) }
    }

    @Test("缓存重载、24 小时过期边界与手动更新")
    func cacheAndExpiry() async throws {
        let file = temporaryCache()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let addresses = try PublicTrackerList.subscriptions("https://example.com/list")
        let response = Responses()
        await response.set(addresses[0][0], text: "udp://tracker.example.com:80/announce")
        let service = PublicTrackerSubscriptionService(fileURL: file, loader: { try await response.load($0) })
        #expect(await service.snapshot().isExpired(at: start))
        try await service.refresh(subscriptions: addresses, now: start)
        #expect(await response.calls.count == 1)
        let saved = await service.snapshot()
        #expect(saved.updatedAt == start)
        #expect(!saved.isExpired(at: start.addingTimeInterval(86_399)))
        #expect(!saved.isExpired(at: start.addingTimeInterval(-1)))
        #expect(saved.isExpired(at: start.addingTimeInterval(86_400)))
        let restored = PublicTrackerSubscriptionService(fileURL: file, loader: { try await response.load($0) })
        #expect(await restored.snapshot() == saved)
        try await restored.refresh(subscriptions: addresses, now: start.addingTimeInterval(86_399))
        #expect(await response.calls.count == 1)
        try await restored.refresh(subscriptions: addresses, force: true, now: start.addingTimeInterval(10))
        #expect(await response.calls.count == 2)
        try await restored.refresh(subscriptions: addresses, now: start.addingTimeInterval(86_410))
        #expect(await response.calls.count == 3)
    }

    @Test("主地址无效时使用备用地址，部分失败保留旧结果，移除来源即时排除")
    func fallbackAndFailureRetention() async throws {
        let file = temporaryCache()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let addresses = try PublicTrackerList.subscriptions("https://example.com/a | https://mirror.example.com/a\nhttps://example.com/b")
        let response = Responses()
        await response.set(addresses[0][0], text: "<html>bad gateway</html>")
        await response.set(addresses[0][1], text: "https://tracker.example.com/a\nhttps://tracker.example.com/a")
        await response.set(addresses[1][0], text: "https://tracker.example.com/b")
        let service = PublicTrackerSubscriptionService(fileURL: file, loader: { try await response.load($0) })
        #expect(try await service.refresh(subscriptions: addresses, now: start) == 0)
        #expect(await response.calls == [addresses[0][0], addresses[0][1], addresses[1][0]])
        #expect(await service.snapshot().trackers(for: addresses) == ["https://tracker.example.com/a", "https://tracker.example.com/b"])
        await response.fail(addresses[0][0])
        await response.fail(addresses[0][1])
        await response.set(addresses[1][0], text: "https://tracker.example.com/c")
        #expect(try await service.refresh(subscriptions: addresses, force: true, now: start.addingTimeInterval(10)) == 1)
        #expect(await service.snapshot().trackers(for: addresses) == ["https://tracker.example.com/a", "https://tracker.example.com/c"])
        let retained = await service.snapshot()
        await response.fail(addresses[1][0])
        #expect(try await service.refresh(subscriptions: addresses, force: true, now: start.addingTimeInterval(20)) == 2)
        #expect(await service.snapshot().entries == retained.entries)
        #expect(await service.snapshot().updatedAt == retained.updatedAt)
        #expect(await service.snapshot().trackers(for: [addresses[1]]) == ["https://tracker.example.com/c"])
        try await service.refresh(subscriptions: [], force: true, now: start.addingTimeInterval(30))
        #expect(await service.snapshot().entries.isEmpty)
    }

    @Test("失败尝试持久化，重启不重复自动请求；超大响应保留缓存")
    func failedAttemptPersists() async throws {
        let file = temporaryCache()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let addresses = try PublicTrackerList.subscriptions("https://example.com/list")
        let response = Responses()
        let service = PublicTrackerSubscriptionService(fileURL: file, loader: { try await response.load($0) })
        #expect(try await service.refresh(subscriptions: addresses, now: start) == 1)
        #expect(await service.snapshot().updatedAt == nil)
        let restarted = PublicTrackerSubscriptionService(fileURL: file, loader: { try await response.load($0) })
        try await restarted.refresh(subscriptions: addresses, now: start.addingTimeInterval(1))
        #expect(await response.calls.count == 1)
        await response.set(addresses[0][0], text: "https://tracker.example.com/announce")
        try await restarted.refresh(subscriptions: addresses, force: true, now: start.addingTimeInterval(2))
        await response.set(addresses[0][0], text: String(repeating: "x", count: PublicTrackerList.maximumResponseSize + 1))
        #expect(try await restarted.refresh(subscriptions: addresses, force: true, now: start.addingTimeInterval(3)) == 1)
        #expect(await restarted.snapshot().trackers(for: addresses) == ["https://tracker.example.com/announce"])
    }

    @Test("损坏缓存忽略，缓存中的无效 tracker 重新验证")
    func invalidCache() async throws {
        let file = temporaryCache()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try Data("broken".utf8).write(to: file)
        #expect(await PublicTrackerSubscriptionService(fileURL: file).snapshot().entries.isEmpty)
        var cache = PublicTrackerCache()
        cache.entries["https://example.com/list"] = ["file:///invalid", "https://tracker.example.com/announce"]
        try JSONEncoder().encode(cache).write(to: file)
        let loaded = await PublicTrackerSubscriptionService(fileURL: file).snapshot()
        #expect(loaded.entries["https://example.com/list"] == ["https://tracker.example.com/announce"])
    }

    private func temporaryCache() -> URL {
        FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "trackers.json")
    }

    private actor Responses {
        private var values: [URL: Data] = [:]
        private(set) var calls: [URL] = []

        func set(_ url: URL, text: String) { values[url] = Data(text.utf8) }
        func fail(_ url: URL) { values[url] = nil }
        func load(_ url: URL) throws -> Data {
            calls.append(url)
            guard let value = values[url] else { throw URLError(.timedOut) }
            return value
        }
    }
}

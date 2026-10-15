import Foundation
import Testing
@testable import MuleeCore

@Suite struct TorrentClientTests {
    @Test("自增请求 id，乱序响应和带字符串 id 的事件互不干扰")
    func outOfOrder() async throws {
        let fake = TorrentFakeTransport(automaticReplies: false)
        let client = TorrentdClient(transport: fake)
        try await client.start()
        try await client.waitUntilReady()
        var requests = fake.requests.makeAsyncIterator()
        let first = Task { try await client.call("first", TorrentdEmpty(), as: String.self) }
        let a = try #require(await requests.next())
        let second = Task { try await client.call("second", TorrentdEmpty(), as: String.self) }
        let b = try #require(await requests.next())
        #expect(b.id == a.id + 1)
        await fake.emit(Data("{\"event\":\"finished\",\"id\":\"torrent-id\"}\n".utf8))
        try await fake.reply(b, result: .string("second"))
        try await fake.reply(a, result: .string("first"))
        #expect(try await first.value == "first")
        #expect(try await second.value == "second")
        var events = client.events.makeAsyncIterator()
        #expect(await events.next()?.event == "ready")
        #expect(await events.next()?.id == "torrent-id")
        await client.finish(grace: .zero)
    }

    @Test("逐行读取跨 chunk 消息和同一 chunk 内多条消息")
    func framing() async throws {
        let fake = TorrentFakeTransport(sendsReady: false, automaticReplies: false)
        let client = TorrentdClient(transport: fake)
        try await client.start()
        await fake.emit(Data("{\"event\":\"rea".utf8))
        await fake.emit(Data("dy\"}\n{\"event\":\"metadata_received\",\"id\":\"abc\"}\n".utf8))
        try await client.waitUntilReady()
        var events = client.events.makeAsyncIterator()
        #expect(await events.next()?.event == "ready")
        #expect(await events.next()?.event == "metadata_received")
        await client.finish(grace: .zero)
    }

    @Test("单请求超时，迟到响应不会影响后续请求")
    func timeout() async throws {
        let fake = TorrentFakeTransport(automaticReplies: false)
        let client = TorrentdClient(transport: fake, requestTimeout: .milliseconds(20))
        try await client.start()
        try await client.waitUntilReady()
        await #expect(throws: EngineError.rpc(code: -1, message: String(localized: "BT 引擎响应超时", bundle: .module))) {
            let _: String = try await client.call("timeout", TorrentdEmpty())
        }
        let request = try #require(await fake.sent.first)
        try await fake.reply(request, result: .string("late"))
        var requests = fake.requests.makeAsyncIterator()
        _ = await requests.next()
        let next = Task { try await client.call("next", TorrentdEmpty(), as: String.self) }
        let second = try #require(await requests.next())
        try await fake.reply(second, result: .string("ok"))
        #expect(try await next.value == "ok")
        await client.finish(grace: .zero)
    }

    @Test("进程退出让所有挂起请求立即失败")
    func exitFailsPending() async throws {
        let fake = TorrentFakeTransport(automaticReplies: false)
        let client = TorrentdClient(transport: fake)
        try await client.start()
        try await client.waitUntilReady()
        var requests = fake.requests.makeAsyncIterator()
        let first = Task { try await client.call("one", TorrentdEmpty(), as: String.self) }
        _ = await requests.next()
        let second = Task { try await client.call("two", TorrentdEmpty(), as: String.self) }
        _ = await requests.next()
        await fake.crash()
        await #expect(throws: EngineError.notRunning) { try await first.value }
        await #expect(throws: EngineError.notRunning) { try await second.value }
        await client.finish(grace: .zero)
    }

    @Test("请求取消会移除 continuation，其他请求仍可继续")
    func cancellation() async throws {
        let fake = TorrentFakeTransport(automaticReplies: false)
        let client = TorrentdClient(transport: fake)
        try await client.start()
        try await client.waitUntilReady()
        var requests = fake.requests.makeAsyncIterator()
        let task = Task { try await client.call("cancel", TorrentdEmpty(), as: String.self) }
        let request = try #require(await requests.next())
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await fake.reply(request, result: .string("ignored"))
        #expect(await client.isRunning())
        await client.finish(grace: .zero)
    }

    @Test("辅助进程错误码转换成中文")
    func chineseError() async throws {
        let fake = TorrentFakeTransport(automaticReplies: false)
        let client = TorrentdClient(transport: fake)
        try await client.start()
        try await client.waitUntilReady()
        var requests = fake.requests.makeAsyncIterator()
        let task = Task { try await client.call("add", TorrentdEmpty(), as: String.self) }
        let request = try #require(await requests.next())
        let response = TorrentdResponse(id: request.id, result: nil, error: TorrentdError(code: "invalid_torrent", message: "bad data"))
        await fake.emit(try JSONEncoder().encode(response) + Data([10]))
        let reason = String(localized: "种子文件或磁力链接无效", bundle: .module)
        let code = "invalid_torrent"
        let expectedError = String(localized: "\(reason)（torrentd 错误码 \(code)）", bundle: .module)
        await #expect(throws: EngineError.rpc(code: 5, message: expectedError)) {
            try await task.value
        }
        await client.finish(grace: .zero)
    }
}

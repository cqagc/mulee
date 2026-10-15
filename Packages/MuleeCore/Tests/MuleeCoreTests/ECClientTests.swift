import Foundation
import Testing
@testable import MuleeCore

struct ECClientTests {
    @Test("MD5 挑战固定向量")
    func challengeVector() {
        #expect(ECAuthentication.passwordHash("password") == "5f4dcc3b5aa765d61d8327deb882cf99")
        #expect(ECTag.hex(ECAuthentication.response(password: "密碼-test", salt: 0xABCDEF123456)) == "6482EA26513908D025093C375366D769")
    }

    @Test("认证不宣告加密或 notify，并发请求不会串包")
    func authenticationAndSerialization() async throws {
        let server = try ECFakeServer()
        await server.start()
        let client = ECClient(port: server.port, password: "密碼-test")
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for value in 0..<20 {
                    group.addTask {
                        let response = try await client.request(ECPacket(opcode: 6, tags: [.number(0, UInt64(value))]))
                        #expect(response.tag(0)?.number == UInt64(value))
                    }
                }
                try await group.waitForAll()
            }
            let requests = await server.requests
            #expect(requests.first?.tags.map(\.name) == [0x100, 0x101, 2])
            #expect(await server.authentications == 1)
            #expect(requests.count == 22)
            await client.disconnect()
            try await server.stop()
        } catch {
            await client.disconnect()
            try await server.stop()
            throw error
        }
    }

    @Test("拒绝错误密码")
    func rejectsPassword() async throws {
        let server = try ECFakeServer(rejectAuthentication: true)
        await server.start()
        let client = ECClient(port: server.port, password: "wrong")
        await #expect(throws: ECError.authentication) { try await client.connect() }
        await client.disconnect()
        try await server.stop()
    }

    @Test("单请求超时和取消会断开 socket", arguments: [false, true])
    func timeoutAndCancellation(cancel: Bool) async throws {
        let server = try ECFakeServer(hangRequests: true)
        await server.start()
        // 认证不是本测试的计时对象；取消分支也不能先被请求超时抢走。
        let client = ECClient(port: server.port, password: "密碼-test", timeout: cancel ? .seconds(30) : .seconds(1))
        do {
            try await client.connect(deadline: ContinuousClock.now.advanced(by: .seconds(30)))
        } catch {
            await client.disconnect()
            try await server.stop()
            throw error
        }
        let operation = Task { try await client.request(ECPacket(opcode: 6)) }
        do {
            if cancel {
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                while await server.requests.count < 3, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(5))
                }
                try #require(await server.requests.count == 3, "取消前必须确认服务端已收到请求")
                operation.cancel()
                await #expect(throws: CancellationError.self) { try await operation.value }
            } else {
                await #expect(throws: ECError.timeout) { try await operation.value }
            }
        } catch {
            operation.cancel()
            _ = await operation.result
            await client.disconnect()
            try await server.stop()
            throw error
        }
        await client.disconnect()
        try await server.stop()
    }

    @Test("断线后重新认证；不自动重放可能已执行的请求")
    func reconnects() async throws {
        let server = try ECFakeServer(closeAfterReply: true)
        await server.start()
        let client = ECClient(port: server.port, password: "密碼-test")
        do {
            _ = try await client.request(ECPacket(opcode: 6))
            await #expect(throws: ECError.disconnected) { try await client.request(ECPacket(opcode: 6)) }
            _ = try await client.request(ECPacket(opcode: 6))
            #expect(await server.authentications == 2)
            await client.disconnect()
            try await server.stop()
        } catch {
            await client.disconnect()
            try await server.stop()
            throw error
        }
    }
}

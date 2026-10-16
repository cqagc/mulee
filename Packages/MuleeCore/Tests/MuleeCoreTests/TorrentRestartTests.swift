import Foundation
import Testing
@testable import MuleeCore

@Suite struct TorrentRestartTests {
    @Test("意外退出对 App 可见，退避后仅自动重启一次")
    func restartOnce() async throws {
        let first = TorrentFakeTransport()
        let second = TorrentFakeTransport()
        let sequence = TorrentTransportSequence([first, second])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = TorrentEngine(stateDirectory: root, restartBackoff: .milliseconds(150), transportFactory: { sequence.make() })
        do {
            let mappings = ExtraPortMappings(tcp: [40123], udp: [40126, 40133])
            try await engine.setExtraPortMappings(mappings)
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await first.crash()
            await #expect(throws: EngineError.notRunning) { try await engine.snapshots() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await second.sent.isEmpty {
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(sequence.created == 2)
            #expect(await second.sent.first?.method == "configure")
            // configure 回复之后启动任务还需要一次 actor 调度完成发布。
            while true {
                do {
                    _ = try await engine.snapshots()
                    break
                } catch EngineError.notRunning {
                    guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            let forwarded = await second.sent.first { $0.method == "set_extra_port_mappings" }
            #expect(forwarded?.parameters["tcp"] == .array([.integer(40123)]))
            #expect(forwarded?.parameters["udp"] == .array([.integer(40126), .integer(40133)]))
            await second.crash()
            try await Task.sleep(for: .milliseconds(250))
            #expect(sequence.created == 2)
            await #expect(throws: EngineError.notRunning) { try await engine.snapshots() }
            await engine.stop()
            #expect(!(await first.isRunning()))
            #expect(!(await second.isRunning()))
            try FileManager.default.removeItem(at: root)
        } catch {
            await engine.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @Test("停止取消待执行的自动重启")
    func stopDuringBackoff() async throws {
        let fake = TorrentFakeTransport()
        let sequence = TorrentTransportSequence([fake, TorrentFakeTransport()])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = TorrentEngine(stateDirectory: root, restartBackoff: .milliseconds(100), transportFactory: { sequence.make() })
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root))
            await fake.crash()
            await engine.stop()
            try await Task.sleep(for: .milliseconds(150))
            #expect(sequence.created == 1)
            try FileManager.default.removeItem(at: root)
        } catch {
            await engine.stop()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }
}

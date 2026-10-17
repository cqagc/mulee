import Foundation
import Testing
@testable import MuleeCore

@Suite(.serialized, .enabled(if: Aria2IntegrationFixture.binaryAvailable))
struct TaskLimitsIntegrationTests {
    @Test(arguments: [(Int64(32_768), Int64(262_144)), (Int64(262_144), Int64(32_768))])
    func httpUsesTheSmallerOfGlobalAndTaskLimits(global: Int64, task: Int64) async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            var options = fixture.options
            options.downloadLimit = global
            options.connectionsPerServer = 1
            try await fixture.engine.start(options: options)
            let id = try await fixture.engine.add(link: fixture.link("limits.bin"), directory: nil, context: .init(), paused: true)
            try await fixture.engine.setTaskLimits(id: id, download: task, upload: 0)
            let rpc = try fixture.rpc()
            let taskOptions: [String: String] = try await rpc.call("aria2.getOption", [.string(id)])
            let globalOptions: [String: String] = try await rpc.call("aria2.getGlobalOption")
            #expect(taskOptions["max-download-limit"] == String(task))
            #expect(globalOptions["max-overall-download-limit"] == String(global))
            try await fixture.engine.resume(id)
            let first = try await fixture.waitFor(id) { $0.receivedBytes > 0 }
            let clock = ContinuousClock()
            let start = clock.now
            try await Task.sleep(for: .seconds(4))
            let last = try #require(try await fixture.engine.snapshots().first { $0.engineTaskID == id })
            let elapsed = start.duration(to: clock.now)
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let received = last.receivedBytes - first.receivedBytes
            // 允许一次令牌补充及分块突发；若任一层被覆盖，吞吐会超过此边界数倍。
            #expect(received > 0)
            #expect(Double(received) <= Double(min(global, task)) * (seconds + 2) + 65_536)
            try await fixture.engine.pause(id)
            try await fixture.engine.setTaskLimits(id: id, download: 0, upload: 0)
            let cleared: [String: String] = try await rpc.call("aria2.getOption", [.string(id)])
            #expect(cleared["max-download-limit"] == "0")
        }
    }

    @Test func stoppedHTTPTaskRejectsLimitUpdates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let engine = Aria2Engine(stateDirectory: root)
        await #expect(throws: EngineError.notRunning) {
            try await engine.setTaskLimits(id: "missing", download: 1_000, upload: 0)
        }
    }
}

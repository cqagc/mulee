import Darwin
import Foundation
import Testing
@testable import MuleeCore

/// 仅手工启用，普通 swift test 不访问公网。链接取自既有 spike 日志中的 Ubuntu ISO。
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MULEE_ED2K_NETWORK_SMOKE"] == "1"
    && ProcessInfo.processInfo.environment["MULEE_AMULED"].map { FileManager.default.isExecutableFile(atPath: $0) } ?? false))
struct Ed2kNetworkSmokeTests {
    @Test("真实网络：Ubuntu ISO，观察 180 秒后删除任务、数据并停止")
    func ubuntu() async throws {
        let root = try Ed2kTestDirectory()
        let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MULEE_AMULED"]))
        let state = root.url.appendingPathComponent("state")
        let downloads = root.url.appendingPathComponent("Incoming")
        let engine = Ed2kEngine(stateDirectory: state, binaryURL: binary, settings: Ed2kEngineSettings(
            tcpPort: try ECLoopback.availablePort(), udpPort: try ECLoopback.availablePort()
        ))
        let original = "ed2k://|file|ubuntu-20.04.6-desktop-amd64.iso|4351463424|0550FF1298BF639218ED2A8B90F30FE7|/"
        let link = try #require(Ed2kLinkParser.parse(original))
        var id: String?
        var pid: pid_t?
        var samples: [[String: String]] = []
        var peakSources = 0
        var received: Int64 = 0
        let started = Date()
        // 180 秒是交付冒烟；引导修复可单独用 10 秒检查，不覆盖完整冒烟报告。
        let observationSeconds = ProcessInfo.processInfo.environment["MULEE_ED2K_BOOTSTRAP_CHECK"] == "1" ? 10 : 180
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: downloads))
            pid = try JSONDecoder().decode(Ed2kProcessIdentity.self, from: Data(contentsOf: state.appendingPathComponent("mulee-process.json"))).pid
            id = try await engine.add(link: link, directory: nil)
            let deadline = ContinuousClock.now.advanced(by: .seconds(observationSeconds))
            repeat {
                let snapshots = try await engine.snapshots()
                let network = try await engine.networkStatus()
                let snapshot = snapshots.first { $0.engineTaskID == id }
                var sources = 0
                if case .ed2k(_, let info) = snapshot?.detail { sources = info.sourceCount }
                peakSources = max(peakSources, sources)
                received = max(received, snapshot?.receivedBytes ?? 0)
                samples.append([
                    "time": Date().ISO8601Format(), "ed2kID": network.ed2kID.rawValue,
                    "kad": network.kad.rawValue, "server": network.serverName ?? "",
                    "sources": String(sources), "receivedBytes": String(snapshot?.receivedBytes ?? 0)
                ])
                if ContinuousClock.now >= deadline { break }
                try await Task.sleep(for: min(.seconds(10), ContinuousClock.now.duration(to: deadline)))
            } while true
            if let id { try await engine.remove(id, deleteFiles: true) }
            id = nil
            await engine.stop()
            if let pid { #expect(kill(pid, 0) == -1) }
            let report: [String: Any] = [
                "started": started.ISO8601Format(), "ended": Date().ISO8601Format(),
                "observedSeconds": observationSeconds, "peakSources": peakSources,
                "receivedBytes": received, "samples": samples, "cleaned": true
            ]
            let build = root.url.deletingLastPathComponent().deletingLastPathComponent()
            let reportName = observationSeconds == 180 ? "ed2k-network-smoke" : "ed2k-bootstrap-check"
            let reportURL = build.appendingPathComponent(reportName + ".json")
            let daemonLog = state.appendingPathComponent("logfile")
            try Data(contentsOf: daemonLog).write(to: build.appendingPathComponent(reportName + "-daemon.log"))
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
            print("ED2K_SMOKE: peakSources=\(peakSources), receivedBytes=\(received), final=\(samples.last ?? [:])")
            try root.remove()
        } catch {
            if let id {
                do { try await engine.remove(id, deleteFiles: true) } catch { Issue.record("网络冒烟清理任务失败：\(error)") }
            }
            await engine.stop()
            try root.remove()
            throw error
        }
    }
}

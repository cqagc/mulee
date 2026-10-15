import Darwin
import Foundation
import Testing
@testable import MuleeCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MULEE_AMULED"].map {
    FileManager.default.isExecutableFile(atPath: $0)
} ?? false))
struct Ed2kIntegrationTests {
    @Test("真实 amuled：离线启动、认证、分类、快照、暂停、继续、重启、删除和无残留退出")
    func offlineLifecycle() async throws {
        let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MULEE_AMULED"]))
        let root = try Ed2kTestDirectory()
        let state = root.url.appendingPathComponent("繁體狀態")
        let downloads = root.url.appendingPathComponent("預設下載")
        let alternate = root.url.appendingPathComponent("分類下載")
        let settings = try offlineSettings()
        let engine = Ed2kEngine(stateDirectory: state, binaryURL: binary, settings: settings)
        let original = "ed2k://|file|Mulee-Fictional-EC-Test.bin|1048576|0123456789ABCDEF0123456789ABCDEF|/"
        let link = try #require(Ed2kLinkParser.parse(original))
        var pids: [pid_t] = []
        do {
            await #expect(throws: EngineError.notRunning) { try await engine.snapshots() }
            try await engine.start(options: EngineOptions(downloadDirectory: downloads))
            let identity = try readIdentity(state)
            pids.append(identity.pid)
            let status = try await engine.networkStatus()
            #expect(status.ed2kID == .disconnected)
            #expect(status.kad == .disconnected)
            let id = try await engine.add(link: link, directory: alternate)
            #expect(id == "0123456789ABCDEF0123456789ABCDEF")
            var snapshot = try #require(try await engine.snapshots().first { $0.engineTaskID == id })
            #expect(snapshot.name == "Mulee-Fictional-EC-Test.bin")
            #expect(snapshot.savePath == alternate.appendingPathComponent(snapshot.name))
            #expect(snapshot.status == .waitingForSources)
            guard case .ed2k(_, let info) = snapshot.detail else { throw ECError.malformed("缺少长尾详情") }
            let waitingSince = info.waitingSince
            try await engine.pause(id)
            snapshot = try #require(try await engine.snapshots().first { $0.engineTaskID == id })
            #expect(snapshot.status == .paused)
            try await engine.resume(id)
            snapshot = try #require(try await engine.snapshots().first { $0.engineTaskID == id })
            #expect(snapshot.status == .waitingForSources)
            #expect(try await engine.add(link: link, directory: nil) == id)
            try await engine.apply(options: EngineOptions(downloadDirectory: downloads, downloadLimit: 8192, uploadLimit: 4096))
            await engine.stop()
            #expect(kill(identity.pid, 0) == -1)
            let configBefore = try String(contentsOf: state.appendingPathComponent("amule.conf"), encoding: .utf8)
            try await engine.start(options: EngineOptions(downloadDirectory: downloads))
            pids.append(try readIdentity(state).pid)
            let configAfter = try String(contentsOf: state.appendingPathComponent("amule.conf"), encoding: .utf8)
            #expect(passwordLine(configBefore) != passwordLine(configAfter))
            snapshot = try #require(try await engine.snapshots().first { $0.engineTaskID == id })
            if case .ed2k(_, let restored) = snapshot.detail { #expect(restored.waitingSince == waitingSince) }
            #expect(snapshot.savePath == alternate.appendingPathComponent(snapshot.name))
            // 同目录复用分类；另一个虚构 hash 使用相同目录。
            let second = try #require(Ed2kLinkParser.parse(original.replacingOccurrences(of: "0123456789ABCDEF0123456789ABCDEF", with: "1123456789ABCDEF0123456789ABCDEF")))
            let secondID = try await engine.add(link: second, directory: alternate)
            var changed = settings
            changed.tcpPort = try ECLoopback.availablePort()
            changed.uploadLimit = 8192
            try await engine.configure(changed)
            pids.append(try readIdentity(state).pid)
            #expect(pids[pids.count - 2] != pids.last)
            let config = try String(contentsOf: state.appendingPathComponent("amule.conf"), encoding: .utf8)
            #expect(config.contains("[Cat\\#1]"))
            #expect(!config.contains("[Cat\\#2]"))
            #expect(config.contains("Port=\(changed.tcpPort)\n"))
            #expect(try await engine.snapshots().count == 2)
            try await engine.remove(secondID, deleteFiles: true)
            try await engine.remove(id, deleteFiles: false)
            #expect(try await engine.snapshots().isEmpty)
            await engine.stop()
            for pid in pids { #expect(kill(pid, 0) == -1) }
            #expect(!FileManager.default.fileExists(atPath: state.appendingPathComponent("mulee-process.json").path))
            try root.remove()
        } catch {
            await engine.stop()
            try root.remove()
            throw error
        }
    }

    @Test("真实 amuled：精确身份匹配的旧进程在启动前回收")
    func orphanRecovery() async throws {
        let binary = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MULEE_AMULED"]))
        let root = try Ed2kTestDirectory()
        let settings = try offlineSettings()
        let config = Ed2kConfiguration(stateDirectory: root.url, port: try ECLoopback.availablePort(), password: "fictional",
                                        options: EngineOptions(downloadDirectory: root.url.appendingPathComponent("Incoming")), settings: settings)
        try config.write()
        let old = try Ed2kProcess(binary: binary, stateDirectory: root.url)
        try Ed2kConfiguration.writePrivate(JSONEncoder().encode(old.identity), to: root.url.appendingPathComponent("mulee-process.json"))
        let engine = Ed2kEngine(stateDirectory: root.url, binaryURL: binary, settings: settings)
        do {
            try await engine.start(options: config.options)
            #expect(!old.isRunning)
            let new = try readIdentity(root.url)
            #expect(new.pid != old.identity.pid)
            await engine.stop()
            #expect(kill(new.pid, 0) == -1)
            try root.remove()
        } catch {
            await old.finish()
            await engine.stop()
            try root.remove()
            throw error
        }
    }

    private func offlineSettings() throws -> Ed2kEngineSettings {
        Ed2kEngineSettings(tcpPort: try ECLoopback.availablePort(), udpPort: try ECLoopback.availablePort(),
                           connectToServers: false, enableKad: false)
    }

    private func readIdentity(_ directory: URL) throws -> Ed2kProcessIdentity {
        try JSONDecoder().decode(Ed2kProcessIdentity.self, from: Data(contentsOf: directory.appendingPathComponent("mulee-process.json")))
    }

    private func passwordLine(_ config: String) -> String? {
        config.split(separator: "\n").first { $0.hasPrefix("ECPassword=") }.map(String.init)
    }
}

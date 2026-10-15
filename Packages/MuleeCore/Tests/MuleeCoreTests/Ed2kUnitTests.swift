import Darwin
import Foundation
import Testing
@testable import MuleeCore

struct Ed2kUnitTests {
    @Test("aMule 所有文件状态映射", arguments: [
        (UInt64(0), TaskStatus.waitingForSources), (1, .waitingForSources),
        (2, .downloading), (3, .downloading), (4, .failed), (5, .failed),
        (6, .failed), (7, .paused), (8, .downloading), (9, .completed),
        (10, .downloading), (255, .failed)
    ])
    func statuses(code: UInt64, expected: TaskStatus) {
        #expect(Ed2kStatusMapper.status(code: code, stopped: false, rate: 0) == expected)
    }

    @Test("速度、停止与磁盘错误的优先级")
    func statusDetails() throws {
        #expect(Ed2kStatusMapper.status(code: 0, stopped: false, rate: 500) == .downloading)
        #expect(Ed2kStatusMapper.status(code: 1, stopped: true, rate: 500) == .paused)
        #expect(Ed2kStatusMapper.status(code: 7, stopped: false, rate: 500) == .paused)
        #expect(Ed2kStatusMapper.status(code: 4, stopped: true, rate: 500) == .failed)
        let record = Ed2kTaskRecord(hash: String(repeating: "A", count: 32), name: "虛構資料.bin", size: 1024,
                                    directory: URL(fileURLWithPath: "/data"), waitingSince: Date())
        let tag = ECTag.empty(0x300, children: [.number(0x308, 5), .number(0x30a, 3), .number(0x40d, 1)])
        let snapshot = try Ed2kStatusMapper.snapshot(tag: tag, record: record, rank: 7, now: Date())
        #expect(snapshot.errorMessage?.contains(String(localized: "磁盘空间不足（aMule 状态码 5）", bundle: .module)) == true)
        guard case .ed2k(_, let info) = snapshot.detail else { Issue.record("缺少电驴详情"); return }
        #expect(info.queueRank == 7)
        #expect(info.sourceCount == 3)
        #expect(info.completeSourceCount == 1)
    }

    @Test("High / Low ID 与 Kad 状态全表", arguments: [UInt64(0), 1, 4, 5, 12, 13], [UInt64(1234), 0x12345678])
    func network(flags: UInt64, id: UInt64) throws {
        let state = try Ed2kNetworkStatus(tag: .number(ECCode.Tag.connectionState, flags, children: [
            .number(ECCode.Tag.ed2kID, id),
            .empty(ECCode.Tag.server, children: [.string(ECCode.Tag.serverName, "虛構測試伺服器")])
        ]))
        #expect(state.serverConnected == (flags & 1 != 0))
        #expect(state.ed2kID == (flags & 1 == 0 ? .disconnected : id < 0x1000000 ? .low : .high))
        #expect(state.kad == (flags & 4 == 0 ? .disconnected : flags & 8 == 0 ? .open : .firewalled))
        #expect(state.serverName == (flags & 1 == 0 ? nil : "虛構測試伺服器"))
    }

    @Test("amule.conf 保留用户项、覆盖重复受管键、中文路径和权限")
    func configuration() throws {
        let root = try Ed2kTestDirectory()
        defer { try? root.remove() }
        let state = root.url.appendingPathComponent("繁體狀態")
        let downloads = root.url.appendingPathComponent("虛構下載")
        let settings = Ed2kEngineSettings(tcpPort: 40123, udpPort: 40124, connectToServers: false, enableKad: false, uploadLimit: 2049)
        let config = Ed2kConfiguration(stateDirectory: state, port: 40125, password: "secret", options: EngineOptions(downloadDirectory: downloads), settings: settings)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        let existing = "# user comment\n[eMule]\nNick=保留暱稱\nPort=1\nPort=2\nCustom=keep\n[ExternalConnect]\nECAddress=0.0.0.0\nRequireEncryption=1\nECNetworkInterface=en0\n[UserSection]\nUnknown=繁體設定\n"
        try Data(existing.utf8).write(to: config.url)
        try config.write()
        let text = try String(contentsOf: config.url, encoding: .utf8)
        #expect(text.contains("# user comment\n"))
        #expect(text.contains("Nick=保留暱稱"))
        #expect(text.contains("Unknown=繁體設定"))
        #expect(text.contains("Custom=keep"))
        #expect(!text.contains("Port=1\n"))
        #expect(text.components(separatedBy: "Port=40123").count == 3)
        #expect(text.contains("ECAddress=127.0.0.1"))
        #expect(text.contains("RequireEncryption=0\n"))
        #expect(text.contains("ECNetworkInterface=\n"))
        #expect(text.contains("MaxUpload=3\n"))
        #expect(!text.contains("secret"))
        #expect(text.contains("IncomingDir=" + Ed2kConfiguration.universalPath(downloads)))
        #expect(!text.contains("IncomingDir=" + downloads.path))
        #expect((try FileManager.default.attributesOfItem(atPath: state.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((try FileManager.default.attributesOfItem(atPath: config.url.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        for name in ["shareddir.dat", "shareddir-explicit.dat", "shareddir-recursive.dat"] {
            #expect(try Data(contentsOf: state.appendingPathComponent(name)).isEmpty)
        }
        var invalid = config
        invalid.options.downloadDirectory = URL(fileURLWithPath: "/invalid\nECAddress=0.0.0.0")
        #expect(throws: ECError.self) { try invalid.write() }
    }

    @Test("长尾记录跨重启、14 天窗口、写盘节流与完成记录")
    func history() throws {
        let root = try Ed2kTestDirectory()
        defer { try? root.remove() }
        let id = String(repeating: "A", count: 32)
        let now = Date(timeIntervalSince1970: 20000 * 86400)
        var history = try Ed2kHistory(directory: root.url)
        var record = Ed2kTaskRecord(hash: id, name: "虛構.bin", size: 100, directory: root.url, waitingSince: now)
        record.sightings[Ed2kTaskRecord.day(now.addingTimeInterval(-14 * 86400))] = 99
        history.store(record)
        history.observe(id, received: 1, rate: 1, sources: 3, lastComplete: now, now: now)
        try history.flush(now: now)
        let firstWrite = try Data(contentsOf: history.url)
        history.observe(id, received: 4, rate: 1, sources: 3, lastComplete: nil, now: now.addingTimeInterval(10))
        try history.flush(now: now.addingTimeInterval(10))
        #expect(try Data(contentsOf: history.url) == firstWrite)
        try history.flush(now: now.addingTimeInterval(10), force: true)
        var restored = try Ed2kHistory(directory: root.url)
        let saved = try #require(restored.records[id])
        let info = saved.longTail(queueRank: nil, sources: 3, completeSources: 1, now: now)
        #expect(info.waitingSince == now)
        #expect(info.activeTransferDuration == .seconds(10))
        #expect(info.lastCompleteSourceSeen == now)
        #expect(info.dailySourceSightings == Array(repeating: 0, count: 13) + [3])
        restored.observe(id, received: 6, rate: 1, sources: 2, lastComplete: nil, now: now.addingTimeInterval(86400))
        #expect(restored.records[id]?.transferSeconds == 10)
        var completed = try #require(restored.records[id])
        completed.completedAt = now.addingTimeInterval(86400)
        completed.completedPath = root.url.appendingPathComponent("虛構.bin")
        restored.store(completed)
        try restored.flush(force: true)
        let afterRestart = try Ed2kHistory(directory: root.url)
        let snapshot = Ed2kStatusMapper.completed(try #require(afterRestart.records[id]), now: now.addingTimeInterval(86400))
        #expect(snapshot.status == .completed)
        #expect(snapshot.completedAt == completed.completedAt)
        #expect(snapshot.savePath == completed.completedPath)
    }

    @Test("失败回包与未知状态给出中文说明")
    func failureResponses() {
        #expect(throws: ECError.self) { try ECTag.hash(0x300, String(repeating: "+f", count: 16)) }
        let response = ECPacket(opcode: ECCode.Op.failed, tags: [.string(0, "Invalid link or already on list.")])
        #expect(throws: ECError.rejected(String(localized: "链接无效或任务已存在", bundle: .module))) { try response.checked() }
        #expect(throws: ECError.self) { try ECPacket(opcode: 0xff).checked() }
        #expect(Ed2kStatusMapper.safePath(name: "../example.bin", directory: URL(fileURLWithPath: "/data")) == nil)
    }

    @Test("状态目录互斥锁不允许另一个引擎同时恢复进程")
    func stateLock() throws {
        let root = try Ed2kTestDirectory()
        defer { try? root.remove() }
        let lock = try Ed2kStateLock(directory: root.url)
        // 模拟启动其他子进程时继承的同一个 open file description。
        let inherited = dup(lock.descriptor)
        defer { if inherited >= 0 { close(inherited) } }
        try #require(inherited >= 0)
        #expect(throws: EngineError.self) { try Ed2kStateLock(directory: root.url) }
        lock.unlock()
        let replacement = try Ed2kStateLock(directory: root.url)
        replacement.unlock()
    }

    @Test("孤儿回收不误杀路径不符、启动时间不符或本进程")
    func processSafety() async throws {
        let root = try Ed2kTestDirectory()
        defer { try? root.remove() }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["30"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() }; sleeper.waitUntilExit() }
        let identity = try #require(Ed2kProcessIdentity.read(sleeper.processIdentifier))
        let recordURL = root.url.appendingPathComponent("mulee-process.json")
        try JSONEncoder().encode(identity).write(to: recordURL)
        try await Ed2kProcess.recover(stateDirectory: root.url, binary: URL(fileURLWithPath: "/usr/bin/false"))
        #expect(sleeper.isRunning)
        let reused = Ed2kProcessIdentity(pid: identity.pid, executable: identity.executable,
                                        startSeconds: identity.startSeconds + 1, startMicroseconds: identity.startMicroseconds)
        try JSONEncoder().encode(reused).write(to: recordURL)
        try await Ed2kProcess.recover(stateDirectory: root.url, binary: URL(fileURLWithPath: "/bin/sleep"))
        #expect(sleeper.isRunning)
        #expect(Ed2kProcessIdentity.read(getpid()) == nil)
    }
}

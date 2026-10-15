import Darwin
import Foundation
import Testing
@testable import MuleeCore

struct YtDlpProcessTests {
    @Test func supervisorTerminatesDescendantsWhenParentExits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-watchdog-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pidFile = root.appendingPathComponent("child.pid")
        let script = root.appendingPathComponent("worker")
        try Data("#!/bin/sh\n/bin/sleep 30 &\necho $! > \"$1\"\nwait\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sleep")
        parent.arguments = ["30"]
        try parent.run()
        let child = try YtDlpProcess(binary: script, arguments: [pidFile.path], parentProcessID: parent.processIdentifier)
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: pidFile.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            parent.terminate()
            while parent.isRunning { try await Task.sleep(for: .milliseconds(20)) }
            while child.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!child.isRunning)
            #expect(kill(pid, 0) != 0)
            await child.terminate()
        } catch {
            if parent.isRunning { parent.terminate() }
            await child.terminate()
            throw error
        }
    }
}

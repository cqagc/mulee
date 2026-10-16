import Darwin
import Foundation
import Testing
@testable import MuleeCore

struct Ed2kProcessSupervisorTests {
    @Test func parentDeathTerminatesTheWorkerAndItsDescendants() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker")
        try Data("""
            #!/bin/sh
            state="$2"
            trap 'echo saved > "$state/saved"; exit 0' TERM
            /bin/sleep 30 &
            echo $! > "$state/descendant.pid"
            wait
            
            """.utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        let parent = Process()
        parent.executableURL = URL(filePath: "/bin/sleep")
        parent.arguments = ["30"]
        try parent.run()
        let child = try Ed2kProcess(binary: worker, stateDirectory: root, parentProcessID: parent.processIdentifier)
        do {
            let file = root.appendingPathComponent("descendant.pid")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let pid = try #require(Int32(String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            parent.terminate()
            while parent.isRunning { try await Task.sleep(for: .milliseconds(20)) }
            while child.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            #expect(!child.isRunning)
            #expect(kill(pid, 0) != 0)
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("saved").path))
            await child.finish()
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        } catch {
            if parent.isRunning { parent.terminate() }
            await child.finish()
            throw error
        }
    }
}

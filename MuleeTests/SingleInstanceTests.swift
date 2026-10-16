import AppKit
import Darwin
import Foundation
import Testing
@testable import Mulee

@Suite @MainActor struct SingleInstanceTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func probe(_ directory: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", """
        import fcntl, os, sys
        fd = os.open(os.path.join(sys.argv[1], 'instance.lock'), os.O_RDWR | os.O_CREAT, 0o600)
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            sys.exit(73)
        """, directory.path]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test func processLockExcludesChildAndReleasesOnClose() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var lock = try SingleInstanceLock.acquire(in: directory)
        #expect(lock != nil)
        #expect(try SingleInstanceLock.acquire(in: directory) == nil)
        #expect(try SingleInstanceLock.ownerProcessID(in: directory) == getpid())
        #expect(try probe(directory) == 73)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        lock = nil
        #expect(try probe(directory) == 0)
    }

    @Test func kernelReleasesLockAfterHolderIsKilled() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let process = Process()
        let ready = Pipe()
        process.executableURL = URL(filePath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", """
        import fcntl, os, sys
        fd = os.open(os.path.join(sys.argv[1], 'instance.lock'), os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(fd, fcntl.LOCK_EX)
        print('R', flush=True)
        sys.stdin.read()
        """, directory.path]
        process.standardOutput = ready
        let input = Pipe()
        process.standardInput = input
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        #expect(ready.fileHandleForReading.readData(ofLength: 1) == Data("R".utf8))
        #expect(try SingleInstanceLock.acquire(in: directory) == nil)
        kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
        let lock = try SingleInstanceLock.acquire(in: directory)
        #expect(lock != nil)
        withExtendedLifetime(lock) {}
    }

    @Test func secondaryDoesNotConfigureModelsOrTouchTaskHistory() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primary = try SingleInstanceSession(stateDirectory: directory)
        let sentinel = directory.appending(path: "tasks.json")
        let original = Data("not JSON: secondary must never load, back up or rewrite this".utf8)
        try original.write(to: sentinel)
        let secondary = try SingleInstanceSession(stateDirectory: directory)
        #expect(primary.isPrimary)
        #expect(!secondary.isPrimary)
        let delegate = AppDelegate()
        delegate.configureSingleInstance(secondary, send: { _, _ in }, activate: { _ in }, terminate: {})
        let temporary = try TemporaryDefaults(prefix: "single-instance.")
        defer { temporary.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        delegate.configure(model: model, settings: SettingsModel(defaults: temporary.defaults), usesSampleData: false)
        #expect(delegate.openURLRouter == nil)
        #expect(model.coordinator == nil)
        #expect(try Data(contentsOf: sentinel) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted() == ["instance.lock", "tasks.json"])
        withExtendedLifetime(primary) {}
    }

    @Test func forwardedURLsAndFilesReachPrimaryRouterWithoutLoops() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let primarySession = try SingleInstanceSession(stateDirectory: directory)
        let secondarySession = try SingleInstanceSession(stateDirectory: directory)
        let temporary = try TemporaryDefaults(prefix: "single-instance-router.")
        defer { temporary.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let primary = AppDelegate()
        primary.openURLRouter = OpenURLRouter(model: model, settings: SettingsModel(defaults: temporary.defaults))
        defer { primary.openURLRouter?.stopCookieCleanup() }
        let secondary = AppDelegate()
        var forwarded: [URL] = []
        var activated: [pid_t] = []
        var terminated = false
        secondary.configureSingleInstance(secondarySession, send: { urls, pid in
            #expect(pid == getpid())
            forwarded += urls
            primary.application(NSApplication.shared, open: urls)
            // 模拟 Launch Services 又把同一事件送回转交实例。
            secondary.application(NSApplication.shared, open: urls)
        }, activate: { activated.append($0) }, terminate: { terminated = true })
        let link = try #require(URL(string: "mulee://add?url=https%3A%2F%2Fexample.org%2Farchive.zip"))
        secondary.application(NSApplication.shared, open: [link])
        secondary.application(NSApplication.shared, openFiles: ["/tmp/fictional.torrent"])
        // 启动后仍会收到事件，不能在第一批转交后立即退出。
        try await Task.sleep(for: .milliseconds(100))
        let late = try #require(URL(string: "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"))
        secondary.application(NSApplication.shared, open: [late])
        #expect(!terminated)
        await secondary.finishSingleInstanceHandoff()
        #expect(terminated)
        #expect(activated == [getpid()])
        #expect(forwarded == [link, URL(filePath: "/tmp/fictional.torrent"), late])
        #expect(model.pendingNewTaskText.components(separatedBy: "\n") == [
            "https://example.org/archive.zip", URL(filePath: "/tmp/fictional.torrent").absoluteString, late.absoluteString
        ])
        #expect(model.tasks.isEmpty)
        withExtendedLifetime(primarySession) {}
    }

    @Test func testHostUsesAnIndependentInjectedStateDirectory() throws {
        #expect(SingleInstanceSession.current.isPrimary)
        #expect(SingleInstanceSession.current.stateDirectory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        let first = SingleInstanceSession.stateDirectory(isRunningUnitTests: true)
        let second = SingleInstanceSession.stateDirectory(isRunningUnitTests: true)
        #expect(first != second)
        #expect(first.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }
        let primary = try SingleInstanceSession(stateDirectory: first)
        let testHost = try SingleInstanceSession(stateDirectory: second)
        #expect(primary.isPrimary)
        #expect(testHost.isPrimary)
        withExtendedLifetime((primary, testHost)) {}
    }
}

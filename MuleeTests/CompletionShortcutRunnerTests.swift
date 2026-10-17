import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct CompletionShortcutRunnerTests {
    private final class Runner: ShortcutProcessRunning {
        var calls: [[String]] = []
        var timeouts: [Duration?] = []
        var output = "First\nSecond Name\n"
        var fails = false
        var active = 0
        var maxActive = 0

        func run(arguments: [String], timeout: Duration?) async throws -> String {
            calls.append(arguments)
            timeouts.append(timeout)
            active += 1
            maxActive = max(maxActive, active)
            defer { active -= 1 }
            await Task.yield()
            if fails { throw SystemShortcutProcessRunner.Failure.exit(1, "test failure") }
            return output
        }
    }

    @Test func namesAndPathsAreSingleArgumentsWithoutShellExpansion() {
        let name = "Example Shortcut; $(example)"
        let path = URL(filePath: "/tmp/Example Folder/sample.bin")
        #expect(CompletionShortcutRunner.arguments(name: name, path: path) == ["run", name, "--input-path", path.path])
    }

    @Test func listsAsynchronouslyWithFiveSecondTimeoutAndEmptyResult() async throws {
        let runner = Runner()
        #expect(try await CompletionShortcutRunner.list(using: runner) == ["First", "Second Name"])
        #expect(runner.calls == [["list"]])
        #expect(runner.timeouts == [.seconds(5)])
        runner.output = "\n"
        #expect(try await CompletionShortcutRunner.list(using: runner).isEmpty)
        runner.fails = true
        await #expect(throws: (any Error).self) { try await CompletionShortcutRunner.list(using: runner) }
    }

    @Test func queueRunsEveryTaskOnceInOrderAndReportsFailures() async throws {
        let storage = try TemporaryDefaults(prefix: "ShortcutQueue-")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        settings.completionShortcut = "Example Shortcut"
        let runner = Runner()
        runner.fails = true
        var notifications: [(String, String)] = []
        let service = CompletionShortcutRunner(settings: settings, runner: runner) { notifications.append(($0, $1)) }
        let first = task(path: "/tmp/first.bin")
        let second = task(path: "/tmp/second.bin")
        service.completed(first)
        service.completed(first)
        service.completed(second)
        await service.waitUntilIdle()
        #expect(runner.calls == [CompletionShortcutRunner.arguments(name: "Example Shortcut", path: first.savePath!),
                                 CompletionShortcutRunner.arguments(name: "Example Shortcut", path: second.savePath!)])
        #expect(runner.maxActive == 1)
        #expect(notifications.count == 2)
        #expect(notifications[0].1.contains("Example Shortcut"))
        #expect(notifications[0].1.contains("test failure"))
        #expect(first.status == .completed)
    }

    @Test func emptySettingAndPreviousCompletionsDoNotRun() async throws {
        let storage = try TemporaryDefaults(prefix: "ShortcutDisabled-")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        #expect(settings.completionShortcut.isEmpty)
        let runner = Runner()
        let previous = task(path: "/tmp/previous.bin")
        let service = CompletionShortcutRunner(settings: settings, completedIDs: [previous.id], runner: runner) { _, _ in Issue.record("Unexpected notification") }
        service.completed(task(path: "/tmp/disabled.bin"))
        settings.completionShortcut = "Example"
        service.completed(previous)
        await service.waitUntilIdle()
        #expect(runner.calls.isEmpty)
        service.stop()
        service.completed(task(path: "/tmp/stopped.bin"))
        await service.waitUntilIdle()
        #expect(runner.calls.isEmpty)
        #expect(SettingsModel(defaults: storage.defaults).completionShortcut == "Example")
        settings.completionShortcut = ""
        #expect(SettingsModel(defaults: storage.defaults).completionShortcut.isEmpty)
    }

    private func task(path: String) -> DownloadTask {
        DownloadTask(
            name: URL(filePath: path).lastPathComponent, fileExtension: "bin", kind: .http,
            status: .completed, totalBytes: 1, receivedBytes: 1, detail: .http(connections: 0),
            postDownload: PostDownloadInfo(autoExtract: false), sourceLink: "https://example.com/file",
            savePath: URL(filePath: path)
        )
    }
}

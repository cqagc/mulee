import Foundation
import Testing
@testable import MuleeCore

struct YtDlpRemovalTests {
    @Test func completedRemovalKeepsFinalFilesAndDoesNotReturnAfterRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-removal-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        try Data(Self.script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let state = root.appendingPathComponent("state")
        let downloads = root.appendingPathComponent("downloads")
        let options = EngineOptions(downloadDirectory: downloads, maxConcurrentDownloads: 1)
        let engine = YtDlpEngine(stateDirectory: state, binaryURL: binary, installer: nil, updatesEnabled: false)
        let restored = YtDlpEngine(stateDirectory: state, binaryURL: binary, installer: nil, updatesEnabled: false)
        do {
            try await engine.start(options: options)
            let url = try #require(URL(string: "https://example.invalid/fixture"))
            let link = ParsedLink.video(url: url, site: .other, original: url.absoluteString)
            let removedID = try await engine.add(link: link, directory: downloads)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: removedID) { $0.status == .completed }
            let keptID = try await engine.add(link: link, directory: downloads)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: keptID) { $0.status == .completed }
            let jobsURL = state.appendingPathComponent("jobs.json")
            let jobs = try JSONDecoder().decode([YtDlpJob].self, from: Data(contentsOf: jobsURL))
            let job = try #require(jobs.first { $0.id == removedID })
            let names = try #require(job.finalFiles)
            #expect(Set(names.map { URL(fileURLWithPath: $0).pathExtension }) == ["mp4", "srt", "ass"])
            #expect(names.allSatisfy { !$0.hasPrefix(removedID) })
            let files = try Dictionary(uniqueKeysWithValues: names.map { name in
                (name, try Data(contentsOf: downloads.appendingPathComponent(name)))
            })

            try await engine.remove(removedID, deleteFiles: false)

            #expect(try await engine.snapshots().map(\.engineTaskID) == [keptID])
            #expect(try JSONDecoder().decode([YtDlpJob].self, from: Data(contentsOf: jobsURL)).map(\.id) == [keptID])
            await engine.stop()
            try await restored.start(options: options)
            #expect(try await restored.snapshots().map(\.engineTaskID) == [keptID])
            #expect(try await restored.snapshots().first?.status == .completed)
            for (name, contents) in files {
                #expect(try Data(contentsOf: downloads.appendingPathComponent(name)) == contents)
            }
            await restored.stop()
        } catch {
            await engine.stop()
            await restored.stop()
            throw error
        }
    }

    @Test func redownloadReusesSavedFormatAndPlaylistEntry() async throws {
        let root = URL.temporaryDirectory.appending(path: UUID().uuidString)
        let state = root.appending(path: "state")
        let downloads = root.appending(path: "downloads")
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        let binary = root.appending(path: "yt-dlp")
        try Data(Self.script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let source = try #require(URL(string: "https://example.invalid/video"))
        let output = downloads.appending(path: "fixture.mp4")
        var job = YtDlpJob(id: UUID().uuidString.lowercased(), url: source, site: .other, directory: downloads,
                           name: "Example", playlistIndex: 3, playlistTitle: "Example", formatID: "18", status: .completed)
        job.savePath = output
        let saved = state.appending(path: "jobs.json")
        try JSONEncoder().encode([job]).write(to: saved)
        let engine = YtDlpEngine(stateDirectory: state, binaryURL: binary, installer: nil, updatesEnabled: false)
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: downloads))
            try await engine.redownload(job.id, directory: downloads)
            let paused = try #require(try JSONDecoder().decode([YtDlpJob].self, from: Data(contentsOf: saved)).first)
            #expect(paused.status == .paused && paused.id == job.id)
            #expect(paused.playlistIndex == 3 && paused.formatID == "18")
            try await engine.resume(job.id)
            let result = try await YtDlpIntegrationFixture.waitFor(engine, id: job.id) { $0.status == .completed }
            let file = try #require(result.savePath)
            #expect(try Data(contentsOf: file) == Data("video".utf8))
            #expect(try await engine.snapshots().count == 1)
        } catch {
            await engine.stop()
            throw error
        }
        await engine.stop()
    }

    private static let script = """
    #!/bin/sh
    if [ "$1" = "--version" ]; then echo fixture; exit 0; fi
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --paths) directory="$2"; shift 2 ;;
            --output) template="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    prefix="${template%%\\%*}"
    file="$directory/${prefix}fixture.mp4"
    printf 'video' > "$file"
    printf 'subtitle' > "$directory/${prefix}fixture.srt"
    printf 'danmaku' > "$directory/${prefix}fixture.ass"
    printf 'MULEE:{"event":"file","path":"%s"}\\n' "$file"
    """
}

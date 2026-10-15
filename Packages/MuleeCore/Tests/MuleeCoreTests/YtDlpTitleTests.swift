import Foundation
import Testing
@testable import MuleeCore

struct YtDlpTitleTests {
    @Test(arguments: [
        ("https://www.bilibili.com/video/BV0000000000?p=1", "雾港序章", "P1 · 雾港序章", "雾港序章"),
        ("https://www.bilibili.com/video/BV0000000000?p=1", "", "P1", "P1"),
        ("https://www.bilibili.com/video/BV0000000000?p=1", "P1 雾港序章", "P1 雾港序章", "P1 雾港序章"),
        ("https://www.bilibili.com/bangumi/play/ep900000011", "第 1 话 · 雾中的来客", "第 1 话 · 雾中的来客", "第 1 话 · 雾中的来客"),
        ("https://www.bilibili.com/bangumi/play/ep900000011", "PV1", "PV1", "PV1")
    ])
    func partTitlesAvoidRepeatedNumbers(source: String, title: String, display: String, task: String) throws {
        let entry = YtDlpPlaylistEntry(index: 1, title: title, url: try #require(URL(string: source)))
        #expect(entry.displayTitle == display)
        #expect(entry.taskTitle == task)
    }

    @Test func metadataKeepsLastUsefulTitle() {
        var progress = YtDlpProgress()
        #expect(progress.consume(#"MULEE:{"event":"metadata","title":"雾港奇谭 \"序章\""}"#) == true)
        #expect(progress.title == "雾港奇谭 \"序章\"")
        for value in ["null", "\"\"", "\"  \"", "\"NA\""] {
            #expect(progress.consume("MULEE:{\"event\":\"metadata\",\"title\":\(value)}") == true)
            #expect(progress.title == "雾港奇谭 \"序章\"")
        }
        #expect(progress.consume("MULEE:{invalid}") == false)
        #expect(progress.title == "雾港奇谭 \"序章\"")
    }

    @Test(arguments: [false, true])
    func extractedTitleUpdatesRunningTaskAndPersists(isPlaylist: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-title-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        try Data(Self.script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let state = root.appendingPathComponent("state")
        let downloads = root.appendingPathComponent("downloads")
        let engine = YtDlpEngine(stateDirectory: state, binaryURL: binary, installer: nil, updatesEnabled: false)
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: downloads))
            let url = try #require(URL(string: isPlaylist
                ? "https://www.bilibili.com/bangumi/play/ep900000011" : "https://example.invalid/fixture"))
            let link = ParsedLink.video(url: url, site: isPlaylist ? .bilibili : .other, original: url.absoluteString)
            let entry = isPlaylist ? YtDlpPlaylistEntry(index: 1, title: "第 1 话 · 雾中的来客", url: url) : nil
            let id = try await engine.add(link: link, directory: downloads, entry: entry, paused: true)
            #expect(try await engine.snapshots().first?.name == (entry?.taskTitle ?? "fixture"))
            // 剧集任务保留列表标题，单个视频改用 yt-dlp 给的真实标题。
            let expected = entry?.taskTitle ?? "雾港奇谭 · 真实标题"
            try await engine.resume(id)
            let running = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .downloading && $0.name == expected }
            #expect(running.status == .downloading)
            let saved = try JSONDecoder().decode([YtDlpJob].self, from: Data(contentsOf: state.appendingPathComponent("jobs.json")))
            #expect(saved.first?.name == expected)
            try Data().write(to: downloads.appendingPathComponent("release"))
            let completed = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .completed }
            #expect(completed.name == expected)
            await engine.stop()
            try await engine.start(options: EngineOptions(downloadDirectory: downloads))
            #expect(try await engine.snapshots().first?.name == expected)
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
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
    printf '%s\\n' 'MULEE:{"event":"metadata","title":"雾港奇谭 · 真实标题"}'
    while [ ! -f "$directory/release" ]; do /bin/sleep 0.02; done
    prefix="${template%%\\%*}"
    file="$directory/${prefix}fixture.mp4"
    /usr/bin/touch "$file"
    printf 'MULEE:{"event":"file","path":"%s"}\\n' "$file"
    """
}

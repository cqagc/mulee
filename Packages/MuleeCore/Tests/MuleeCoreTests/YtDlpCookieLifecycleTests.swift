import Foundation
import Testing
@testable import MuleeCore

struct YtDlpCookieLifecycleTests {
    @Test(arguments: [false, true])
    func cookiesAreRemovedOnSuccessAndFailure(fail: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        try Data(script(fail: fail).utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let engine = YtDlpEngine(stateDirectory: root.appendingPathComponent("state"), binaryURL: binary,
                                 installer: nil, updatesEnabled: false)
        await engine.configureCookies { _ in
            [VideoCookie(domain: ".bilibili.com", path: "/", name: "test", value: "synthetic-secret",
                         secure: true, httpOnly: true, hostOnly: false)]
        }
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            let url = try #require(URL(string: "https://www.bilibili.com/video/BVexample?p=2"))
            let entry = YtDlpPlaylistEntry(index: 2, title: "示例部分", url: url)
            let id = try await engine.add(link: entry.link, directory: nil, entry: entry)
            let result = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { [.completed, .failed].contains($0.status) }
            await engine.stop()
            #expect(result.status == (fail ? .failed : .completed))
            let cookiePath = try String(contentsOf: root.appendingPathComponent("downloads/cookie-path"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!FileManager.default.fileExists(atPath: cookiePath))
            let recorded = try String(contentsOf: root.appendingPathComponent("state/jobs.json"), encoding: .utf8)
            #expect(!recorded.contains("synthetic-secret"))
            let arguments = try String(contentsOf: root.appendingPathComponent("downloads/arguments"), encoding: .utf8)
            #expect(arguments.contains("--playlist-items 2"))
            #expect(arguments.contains("P2 "))
            #expect(!arguments.contains("--cookies-from-browser"))
        } catch {
            await engine.stop()
            throw error
        }
    }

    @Test func cookieFileIsRemovedOnPause() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        try Data(script(fail: false, wait: true).utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let engine = YtDlpEngine(stateDirectory: root.appendingPathComponent("state"), binaryURL: binary, installer: nil)
        await engine.configureCookies { _ in
            [VideoCookie(domain: ".youtube.com", path: "/", name: "test", value: "synthetic",
                         secure: true, httpOnly: false, hostOnly: false)]
        }
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            let url = try #require(URL(string: "https://www.youtube.com/watch?v=example"))
            let id = try await engine.add(link: .video(url: url, site: .youtube, original: url.absoluteString))
            let marker = root.appendingPathComponent("downloads/cookie-path")
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            let cookiePath = try String(contentsOf: marker, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(FileManager.default.fileExists(atPath: cookiePath))
            try await engine.pause(id)
            #expect(!FileManager.default.fileExists(atPath: cookiePath))
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }

    private func script(fail: Bool, wait: Bool = false) -> String {
        """
        #!/bin/sh
        arguments="$*"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --paths) directory="$2"; shift 2 ;;
                --output) template="$2"; shift 2 ;;
                --cookies) cookies="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        [ "$(/usr/bin/stat -f %Lp "$cookies")" = 600 ] || exit 2
        printf '%s\\n' "$cookies" > "$directory/cookie-path"
        printf '%s\\n' "$arguments" > "$directory/arguments"
        \(wait ? "exec /bin/sleep 30" : "")
        \(fail ? "echo synthetic-secret; exit 1" : "")
        prefix="${template%%\\%*}"
        file="$directory/${prefix}fixture.mp4"
        /usr/bin/touch "$file"
        printf 'MULEE:{"event":"file","path":"%s"}\\n' "$file"
        """
    }
}

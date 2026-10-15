import CryptoKit
import Foundation
import Testing
@testable import MuleeCore

struct YtDlpConfigurationTests {
    @Test func channelAndQualityChangesUseNewToolWithoutRestartingEngine() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-config-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let installer = ManagedToolInstaller(directory: root.appendingPathComponent("bin")) { url, destination in
            let nightly = url.absoluteString.contains("nightly")
            let payload = Data(Self.script(marker: nightly ? "nightly" : "stable").utf8)
            if url.lastPathComponent == "SHA2-256SUMS" {
                let digest = SHA256.hash(data: payload).map { byte in
                    let hex = String(byte, radix: 16)
                    return byte < 0x10 ? "0" + hex : hex
                }.joined()
                try Data((digest + "  yt-dlp_macos\n").utf8).write(to: destination)
            } else {
                try payload.write(to: destination)
            }
        }
        let engine = YtDlpEngine(stateDirectory: root.appendingPathComponent("state"), installer: installer)
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            let url = try #require(URL(string: "https://example.invalid/video"))
            let link = ParsedLink.video(url: url, site: .bilibili, original: url.absoluteString)
            let first = try await engine.add(link: link)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: first) { $0.status == .completed }

            try await engine.configure(
                quality: .best, cookiesURL: nil,
                subtitles: YtDlpSubtitles(danmaku: true, closedCaptions: true),
                channel: .nightly, updatesEnabled: false
            )
            let second = try await engine.add(link: link)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: second) { $0.status == .completed }
            let arguments = try String(contentsOf: root.appendingPathComponent("downloads/arguments"), encoding: .utf8)

            #expect(arguments.contains("nightly"))
            #expect(arguments.contains("mkv"))
            #expect(arguments.contains("--write-subs"))
            #expect(arguments.contains("all"))
            #expect(arguments.contains("en_US.UTF-8"))
            #expect(try await engine.snapshots().count == 2)
            #expect(try await installer.installedURL(for: .ytDlp(channel: .nightly)) != nil)
            await engine.stop()

            // 停止期间切换通道，之后启动也必须使用新工具。
            try await engine.configure(
                quality: .compatible, cookiesURL: nil, subtitles: YtDlpSubtitles(),
                channel: .stable, updatesEnabled: false
            )
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            let third = try await engine.add(link: link)
            _ = try await YtDlpIntegrationFixture.waitFor(engine, id: third) { $0.status == .completed }
            let restarted = try String(contentsOf: root.appendingPathComponent("downloads/arguments"), encoding: .utf8)
            #expect(restarted.hasPrefix("stable\n"))
            #expect(restarted.contains("mp4"))
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }

    @Test func retrySettingChangesAreAppliedAfterStartup() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("YtDlp-config-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        let marker = root.appendingPathComponent("updated")
        try Data("#!/bin/sh\necho 'ERROR: fixture failure'\nexit 1\n".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let engine = YtDlpEngine(
            stateDirectory: root.appendingPathComponent("state"), binaryURL: binary, installer: nil,
            updater: {
                try Data("updated".utf8).write(to: marker)
                return binary
            }
        )
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root.appendingPathComponent("downloads")))
            let url = try #require(URL(string: "https://example.invalid/video"))
            let link = ParsedLink.video(url: url, site: .other, original: url.absoluteString)
            for enabled in [false, true] {
                try await engine.configure(
                    quality: .compatible, cookiesURL: nil, subtitles: YtDlpSubtitles(),
                    channel: .stable, updatesEnabled: enabled
                )
                let id = try await engine.add(link: link)
                _ = try await YtDlpIntegrationFixture.waitFor(engine, id: id) { $0.status == .failed }
                #expect(FileManager.default.fileExists(atPath: marker.path) == enabled)
            }
            await engine.stop()
        } catch {
            await engine.stop()
            throw error
        }
    }

    private static func script(marker: String) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then echo fixture; exit 0; fi
        arguments="$*"
        while [ "$#" -gt 0 ]; do
            case "$1" in
                --paths) directory="$2"; shift 2 ;;
                --output) template="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        prefix="${template%%\\%*}"
        file="$directory/${prefix}fixture.mp4"
        printf '%s\\n' '\(marker)' "$arguments" "$LANG" > "$directory/arguments"
        /usr/bin/touch "$file"
        printf 'MULEE:{"event":"file","path":"%s"}\\n' "$file"
        """
    }
}

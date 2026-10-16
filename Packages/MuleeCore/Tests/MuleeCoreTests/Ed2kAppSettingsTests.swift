import Foundation
import Testing
@testable import MuleeCore

struct Ed2kAppSettingsTests {
    @Test("共享过滤与混淆开关写入真实 aMule 配置", arguments: [false, true])
    func sharingAndObfuscation(enabled: Bool) throws {
        let configuration = Ed2kConfiguration(
            stateDirectory: URL(fileURLWithPath: "/tmp/Mulee-state"), port: 4712, password: "test",
            options: EngineOptions(downloadDirectory: URL(fileURLWithPath: "/tmp/Mulee-downloads")),
            settings: Ed2kEngineSettings(shareCompletedFiles: enabled, obfuscation: enabled)
        )

        let values = try configuration.managedValues()

        #expect(values["Obfuscation"]?["IsClientCryptLayerSupported"] == (enabled ? "1" : "0"))
        #expect(values["Obfuscation"]?["IsCryptLayerRequested"] == (enabled ? "1" : "0"))
        #expect(values["Obfuscation"]?["IsClientCryptLayerRequired"] == "0")
        #expect(values["eMule"]?["ExcludeSharePatterns"] == (enabled
            ? ".DS_Store|._*|.Spotlight-V100|.Trashes|.fseventsd|.DocumentRevisions-V100|.TemporaryItems|.apdisk|Thumbs.db|ehthumbs.db|desktop.ini|.directory" : "*"))
        #expect(values["eMule"]?["ExcludeSharePatternsUseRegex"] == "0")
        #expect(values["eMule"]?["ShareHiddenFiles"] == "0")
    }

    @Test("真实 amuled：设置变化重启保留任务，通用限速和目录随后仍可更新", .enabled(if: ProcessInfo.processInfo.environment["MULEE_AMULED"] != nil))
    func liveSettings() async throws {
        let root = try Ed2kTestDirectory()
        let state = root.url.appendingPathComponent("state")
        var settings = Ed2kEngineSettings(
            tcpPort: try ECLoopback.availablePort(), udpPort: try ECLoopback.availablePort(),
            connectToServers: false, enableKad: false
        )
        let engine = Ed2kEngine(
            stateDirectory: state,
            binaryURL: URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["MULEE_AMULED"])),
            settings: settings
        )
        do {
            try await engine.start(options: EngineOptions(downloadDirectory: root.url.appendingPathComponent("downloads")))
            let link = try #require(Ed2kLinkParser.parse("ed2k://|file|Ubuntu-settings.bin|100|0123456789ABCDEF0123456789ABCDEF|/"))
            let id = try await engine.add(link: link, directory: nil)
            let before = try #require(try await engine.snapshots().first)

            settings.shareCompletedFiles = false
            settings.obfuscation = false
            try await engine.configure(settings)
            let after = try #require(try await engine.snapshots().first)
            #expect(after.engineTaskID == id)
            #expect(after.detail == before.detail)
            let directory = root.url.appendingPathComponent("新目录")
            try await engine.apply(options: EngineOptions(downloadDirectory: directory, downloadLimit: 500_000, uploadLimit: 250_000))
            try await engine.apply(options: EngineOptions(
                downloadDirectory: directory, downloadLimit: 500_000, uploadLimit: 250_000, diskCacheMegabytes: 1
            ))
            #expect(try await engine.snapshots().first?.engineTaskID == id)
            let configuration = try String(contentsOf: state.appendingPathComponent("amule.conf"), encoding: .utf8)
            #expect(configuration.contains("FileBufferSizePref=66\n"))
            #expect(configuration.contains("ExcludeSharePatterns=*\n"))
            #expect(configuration.contains("IsClientCryptLayerSupported=0\n"))
            #expect(configuration.contains("IsCryptLayerRequested=0\n"))
            #expect(configuration.contains("IncomingDir=" + Ed2kConfiguration.universalPath(directory)))
            #expect(configuration.contains("MaxDownload=489\n"))
            #expect(configuration.contains("MaxUpload=245\n"))
            #expect(try await engine.networkStatus().ed2kID == .disconnected)
            try await engine.remove(id, deleteFiles: false)
            await engine.stop()
            try root.remove()
        } catch {
            await engine.stop()
            try root.remove()
            throw error
        }
    }
}

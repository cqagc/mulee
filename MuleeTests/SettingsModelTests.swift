import Foundation
import Testing
@testable import Mulee

@Suite struct SettingsModelTests {
    private func makeDefaults() throws -> (UserDefaults, String) {
        let name = "mulee.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        return (defaults, name)
    }

    @Test func defaultValues() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        #expect(model.closeKeepsRunning)
        #expect(!model.watchClipboard)
        #expect(model.maxConcurrentTasks == 5)
        #expect(model.httpThreads == 8)
        #expect(model.saveDirectory.hasSuffix("/Downloads/Mulee"))
        #expect(model.downloadLimit == 0)
        #expect(model.uploadLimit == 2)
        #expect(model.diskCacheMB == 128)
        #expect(model.seedingAction == .throttle)
        #expect(model.privateIgnoresRatio)
        #expect(model.btPort == 51413)
        #expect(model.ed2kTCPPort == 4662)
        #expect(model.ed2kUDPPort == 4672)
        #expect(model.ed2kShare)
        #expect(model.ed2kObfuscation)
        #expect(model.videoQuality == .compatible)
        #expect(model.ytDlpChannel == .stable)
        #expect(model.updateBeforeRetry)
        #expect(model.danmakuToASS)
        #expect(model.autoExtract)
        #expect(model.originalAction == .trash)
        #expect(!model.extractNested)
    }

    @Test func changesPersist() throws {
        let (defaults, name) = try makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        model.maxConcurrentTasks = 7
        model.watchClipboard = true
        model.seedingAction = .stop
        model.filenameEncoding = .shiftJIS
        model.diskCacheMB = 256
        model.saveDirectory = "/tmp/x"

        let reloaded = SettingsModel(defaults: defaults)
        #expect(reloaded.maxConcurrentTasks == 7)
        #expect(reloaded.watchClipboard)
        #expect(reloaded.seedingAction == .stop)
        #expect(reloaded.filenameEncoding == .shiftJIS)
        #expect(reloaded.diskCacheMB == 256)
        #expect(reloaded.saveDirectory == "/tmp/x")
    }
}

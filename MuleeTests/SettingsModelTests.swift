import Foundation
import Testing
@testable import Mulee

@Suite struct SettingsModelTests {
    @Test func defaultValues() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "mulee.tests.")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
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
        #expect(model.publicTrackersEnabled)
        #expect(!model.blockLeechingClients)
        #expect(!model.trackerSubscriptions.isEmpty)
        #expect(model.customTrackers.isEmpty)
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
        let temporaryDefaults = try TemporaryDefaults(prefix: "mulee.tests.")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let model = SettingsModel(defaults: defaults)
        model.publicTrackersEnabled = false
        model.blockLeechingClients = true
        model.trackerSubscriptions = "https://example.com/trackers.txt"
        model.customTrackers = "udp://tracker.example.com:80/announce"
        model.maxConcurrentTasks = 7
        model.watchClipboard = true
        model.seedingAction = .stop
        model.filenameEncoding = .shiftJIS
        model.diskCacheMB = 256
        model.saveDirectory = "/tmp/x"

        let reloaded = SettingsModel(defaults: defaults)
        #expect(!reloaded.publicTrackersEnabled)
        #expect(reloaded.blockLeechingClients)
        #expect(reloaded.trackerSubscriptions == model.trackerSubscriptions)
        #expect(reloaded.customTrackers == model.customTrackers)
        #expect(reloaded.maxConcurrentTasks == 7)
        #expect(reloaded.watchClipboard)
        #expect(reloaded.seedingAction == .stop)
        #expect(reloaded.filenameEncoding == .shiftJIS)
        #expect(reloaded.diskCacheMB == 256)
        #expect(reloaded.saveDirectory == "/tmp/x")
    }

    @Test func everyPickerDefaultIsSelectable() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "mulee.tests.")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let model = SettingsModel(defaults: defaults)

        #expect(SettingsModel.downloadLimitOptions.contains(model.downloadLimit))
        #expect(SettingsModel.uploadLimitOptions.contains(model.uploadLimit))
        #expect(SettingsModel.httpThreadOptions.contains(model.httpThreads))
        #expect(SettingsModel.SeedingAction.allCases.contains(model.seedingAction))
        #expect(SettingsModel.VideoQuality.allCases.contains(model.videoQuality))
        #expect(SettingsModel.YtDlpChannel.allCases.contains(model.ytDlpChannel))
        #expect(SettingsModel.FilenameEncoding.allCases.contains(model.filenameEncoding))
        #expect(SettingsModel.OriginalArchiveAction.allCases.contains(model.originalAction))
    }

    @Test("上传限速支持小数且仍以 MB/s 持久化", arguments: [0.0, 0.5, 1, 2, 5, 10])
    func uploadLimitPersistsInMegabytes(_ limit: Double) throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "mulee.tests.")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let model = SettingsModel(defaults: defaults)

        model.uploadLimit = limit

        #expect(SettingsModel.uploadLimitOptions.contains(limit))
        #expect(defaults.double(forKey: "network.uploadLimitMBps") == limit)
        #expect(SettingsModel(defaults: defaults).uploadLimit == limit)
    }

    @Test("既有整数上传限速按 MB/s 读取", arguments: [0, 1, 2, 5, 10, 20])
    func legacyIntegerUploadLimitKeepsItsUnit(_ limit: Int) throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "mulee.tests.")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        defaults.set(limit, forKey: "network.uploadLimitMBps")

        #expect(SettingsModel(defaults: defaults).uploadLimit == Double(limit))
    }
}

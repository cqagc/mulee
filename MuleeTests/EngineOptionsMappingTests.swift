import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct EngineOptionsMappingTests {
    @Test func mapsEveryEngineSettingWithDecimalMegabytes() throws {
        let temporaryDefaults = try TemporaryDefaults(prefix: "mulee.engine-options.")
        defer { temporaryDefaults.clean() }
        let defaults = temporaryDefaults.defaults
        let settings = SettingsModel(defaults: defaults)
        settings.saveDirectory = "/tmp/chosen"
        settings.maxConcurrentTasks = 7
        settings.httpThreads = 16
        settings.downloadLimit = 5
        settings.uploadLimit = 0.5
        settings.diskCacheMB = 256

        let mapped = EngineOptionsMapper.options(from: settings)

        #expect(mapped.downloadDirectory == URL(filePath: "/tmp/chosen", directoryHint: .isDirectory))
        #expect(mapped.maxConcurrentDownloads == 7)
        #expect(mapped.connectionsPerServer == 16)
        #expect(mapped.downloadLimit == 5_000_000)
        #expect(mapped.uploadLimit == 500_000)
        #expect(mapped.diskCacheMegabytes == 256)

        settings.downloadLimit = 0
        settings.uploadLimit = 0
        let unlimited = EngineOptionsMapper.options(from: settings)
        #expect(unlimited.downloadLimit == 0)
        #expect(unlimited.uploadLimit == 0)
    }
}

import Foundation
import Testing
@testable import MuleeCore

@Suite struct BandwidthCacheTests {
    @Test("aMule 缓冲按 15000 字节换算并限制在 uint8 范围", arguments: [0, 1, 3, 4, 128, 512])
    func fileBuffer(megabytes: Int) throws {
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), diskCacheMegabytes: megabytes)
        let configuration = Ed2kConfiguration(
            stateDirectory: URL(filePath: "/tmp"), port: 1234, password: "fixture",
            options: options, settings: Ed2kEngineSettings()
        )

        let values = try configuration.managedValues()

        #expect(values["eMule"]?["FileBufferSizePref"] == String(min(255, megabytes * 1_000_000 / 15_000)))
    }
}

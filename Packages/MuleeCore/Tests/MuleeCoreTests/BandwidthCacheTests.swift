import Foundation
import Testing
@testable import MuleeCore

@Suite struct BandwidthCacheTests {
    @Test("aMule 缓冲按 15000 字节换算并限制在 uint8 范围", arguments: [(-1, 0), (0, 0), (1, 66), (3, 200), (4, 255), (128, 255), (Int.max, 255)])
    func fileBuffer(megabytes: Int, expected: Int) throws {
        let options = EngineOptions(downloadDirectory: URL(filePath: "/tmp"), diskCacheMegabytes: megabytes)
        let configuration = Ed2kConfiguration(
            stateDirectory: URL(filePath: "/tmp"), port: 1234, password: "fixture",
            options: options, settings: Ed2kEngineSettings()
        )

        let values = try configuration.managedValues()

        #expect(values["eMule"]?["FileBufferSizePref"] == String(expected))
    }

    @Test("aria2 启动配置保留有界缓存和稀疏分配", arguments: [(-1, "0M"), (0, "0M"), (128, "128M"), (512, "512M")])
    func aria2Cache(megabytes: Int, expected: String) throws {
        let configuration = Aria2Configuration(
            stateDirectory: URL(filePath: "/tmp"), port: 1234, secret: "fixture",
            options: EngineOptions(downloadDirectory: URL(filePath: "/tmp"), diskCacheMegabytes: megabytes)
        )
        let contents = try configuration.contents()
        #expect(contents.contains("disk-cache=\(expected)\n"))
        #expect(contents.contains("file-allocation=none\n"))
        #expect(configuration.runtimeOptions["disk-cache"] == nil)
    }

    @Test func throttledVideoBufferKeepsProgressResponsive() {
        let options = EngineOptions(
            downloadDirectory: URL(filePath: "/tmp"), maxConcurrentDownloads: 2,
            downloadLimit: 262_144, diskCacheMegabytes: 128
        )
        #expect(YtDlpEngine.downloadBufferBytes(options) == 131_072)
    }

    @Test("视频缓冲按并发分配并限制单进程上限", arguments: [
        (-1, 1, 1024), (0, 1, 1024), (1, 2, 524_288),
        (32, 8, 4_194_304), (128, 1, 16_777_216), (Int.max, 1, 16_777_216)
    ])
    func videoCache(megabytes: Int, workers: Int, expected: Int) {
        let options = EngineOptions(
            downloadDirectory: URL(filePath: "/tmp"), maxConcurrentDownloads: workers, diskCacheMegabytes: megabytes
        )
        #expect(YtDlpEngine.downloadBufferBytes(options) == expected)
    }
}

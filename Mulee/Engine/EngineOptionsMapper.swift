import Foundation
import MuleeCore

/// 设置快照到引擎配置的纯映射；MB/s 使用十进制单位。
enum EngineOptionsMapper {
    static func options(from settings: SettingsModel) -> EngineOptions {
        EngineOptions(
            downloadDirectory: URL(filePath: settings.saveDirectory, directoryHint: .isDirectory),
            maxConcurrentDownloads: settings.maxConcurrentTasks,
            connectionsPerServer: settings.httpThreads,
            downloadLimit: Int64(settings.downloadLimit) * 1_000_000,
            uploadLimit: Int64(settings.uploadLimit * 1_000_000),
            diskCacheMegabytes: Int(settings.diskCacheMB)
        )
    }
}

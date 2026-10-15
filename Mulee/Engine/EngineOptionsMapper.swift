import Foundation
import MuleeCore

/// 设置快照到引擎配置的纯映射；MB/s 使用十进制单位。
enum EngineOptionsMapper {
    static func options(from settings: SettingsModel, now: Date = Date(), calendar: Calendar = .current) -> EngineOptions {
        let scheduled = ScheduledSpeedLimit.isActive(settings: settings, now: now, calendar: calendar)
        return EngineOptions(
            downloadDirectory: URL(filePath: settings.saveDirectory, directoryHint: .isDirectory),
            maxConcurrentDownloads: settings.maxConcurrentTasks,
            connectionsPerServer: settings.httpThreads,
            downloadLimit: Int64(scheduled ? settings.scheduledDownloadLimit : settings.downloadLimit) * 1_000_000,
            uploadLimit: Int64((scheduled ? settings.scheduledUploadLimit : settings.uploadLimit) * 1_000_000),
            diskCacheMegabytes: Int(settings.diskCacheMB)
        )
    }
}

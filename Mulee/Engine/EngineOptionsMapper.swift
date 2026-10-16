import Foundation
import MuleeCore

/// 设置快照到引擎配置的纯映射；MB/s 使用十进制单位。
enum EngineOptionsMapper {
    static func options(from settings: SettingsModel, now: Date = Date(), calendar: Calendar = .current, slowMode: Bool = false) -> EngineOptions {
        let scheduled = ScheduledSpeedLimit.isActive(settings: settings, now: now, calendar: calendar)
        let download = Double(scheduled ? settings.scheduledDownloadLimit : settings.downloadLimit)
        let upload = scheduled ? settings.scheduledUploadLimit : settings.uploadLimit
        return EngineOptions(
            downloadDirectory: URL(filePath: settings.saveDirectory, directoryHint: .isDirectory),
            maxConcurrentDownloads: settings.maxConcurrentTasks,
            connectionsPerServer: settings.httpThreads,
            downloadLimit: bytesPerSecond(download, slow: slowMode ? settings.slowModeDownloadMBps : nil),
            uploadLimit: bytesPerSecond(upload, slow: slowMode ? settings.slowModeUploadMBps : nil),
            diskCacheMegabytes: Int(settings.diskCacheMB)
        )
    }

    private static func bytesPerSecond(_ limit: Double, slow: Double?) -> Int64 {
        let values = [limit, slow ?? 0].filter { $0.isFinite && $0 > 0 }
        return Int64(min(values.min() ?? 0, 1_000_000_000) * 1_000_000)
    }
}

import Foundation
import MuleeCore

enum TaskTrash {
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    static func isExpired(_ task: DownloadTask, now: Date) -> Bool {
        task.deletedAt.map { now.timeIntervalSince($0) >= retention } ?? false
    }

    static func move(_ task: inout DownloadTask, now: Date) {
        task.deletedAt = now
        task.pauseReason = nil
        task.downloadRate = 0
        task.uploadRate = 0
        task.estimatedTimeRemaining = nil
    }
}

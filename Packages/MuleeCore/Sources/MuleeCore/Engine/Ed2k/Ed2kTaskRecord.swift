import Foundation

/// 与 amuled 的队列独立保存，完成后也能继续报告同一 hash。
struct Ed2kTaskRecord: Codable, Sendable {
    var hash: String
    var name: String
    var size: Int64
    var received: Int64 = 0
    var directory: URL
    var source: String?
    var waitingSince: Date
    var transferSeconds: Double = 0
    var sightings: [String: Int] = [:]
    var lastSighting: Date?
    var lastCompleteSourceSeen: Date?
    var completedAt: Date?
    var completedPath: URL?

    func longTail(queueRank: Int?, sources: Int, completeSources: Int, now: Date) -> LongTailInfo {
        LongTailInfo(
            queueRank: queueRank, sourceCount: sources, completeSourceCount: completeSources,
            lastCompleteSourceSeen: lastCompleteSourceSeen, waitingSince: waitingSince,
            activeTransferDuration: .seconds(transferSeconds),
            dailySourceSightings: (0..<14).map { offset in
                sightings[Self.day(now.addingTimeInterval(Double(offset - 13) * 86400))] ?? 0
            }
        )
    }

    static func day(_ date: Date) -> String {
        String(Int(floor(date.timeIntervalSince1970 / 86400)))
    }
}

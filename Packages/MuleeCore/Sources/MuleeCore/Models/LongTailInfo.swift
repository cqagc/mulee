import Foundation

/// 电驴长尾任务的等待信息，用于详情栏「长尾任务」卡片。
public struct LongTailInfo: Sendable, Hashable, Codable {
    /// 在对方上传队列中的排位；nil 表示当前不在任何队列里。
    public var queueRank: Int?
    /// 当前已知来源数。
    public var sourceCount: Int
    /// 其中拥有完整文件的来源数。
    public var completeSourceCount: Int
    /// 最后一次见到完整来源的时间；nil 表示从未见过。
    public var lastCompleteSourceSeen: Date?
    /// 任务开始等待的时间，用于计算「已挂 N 天」。
    public var waitingSince: Date
    /// 实际传输数据的累计时长。
    public var activeTransferDuration: Duration
    /// 最近 14 天每天见到的来源数，下标 0 是 13 天前，最后一个是今天。
    public var dailySourceSightings: [Int]

    public init(
        queueRank: Int?,
        sourceCount: Int,
        completeSourceCount: Int,
        lastCompleteSourceSeen: Date?,
        waitingSince: Date,
        activeTransferDuration: Duration,
        dailySourceSightings: [Int]
    ) {
        self.queueRank = queueRank
        self.sourceCount = sourceCount
        self.completeSourceCount = completeSourceCount
        self.lastCompleteSourceSeen = lastCompleteSourceSeen
        self.waitingSince = waitingSince
        self.activeTransferDuration = activeTransferDuration
        self.dailySourceSightings = dailySourceSightings
    }
}

/// 任务当前所处的阶段。
public enum TaskStatus: String, Sendable, Hashable, Codable {
    /// 正在下载数据。
    case downloading
    /// 已加入引擎队列，等待空位开始（受「同时进行的任务数」限制）。
    case queued
    /// 电驴等长尾任务：暂时没有可用来源，挂着等待。不是失败。
    case waitingForSources
    /// BT 下载完成后做种。
    case seeding
    /// 下载完成后正在解压。
    case extracting
    /// 视频下载后合并音视频等后处理。
    case postProcessing
    /// 用户手动暂停。
    case paused
    /// 全部完成。
    case completed
    /// 出错，需要用户处理。
    case failed
    /// 对应的下载引擎还没有接入（例如 BT、电驴、视频引擎开发中），任务只记录不下载。
    case engineUnavailable
}

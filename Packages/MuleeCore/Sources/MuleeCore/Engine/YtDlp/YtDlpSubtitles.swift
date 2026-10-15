/// Bilibili 字幕选择。弹幕先下载 XML，任务后处理时转换为 ASS。
public struct YtDlpSubtitles: Sendable {
    public var danmaku: Bool
    public var closedCaptions: Bool

    public init(danmaku: Bool = false, closedCaptions: Bool = false) {
        self.danmaku = danmaku
        self.closedCaptions = closedCaptions
    }

    public var arguments: [String] {
        guard danmaku || closedCaptions else { return [] }
        let languages = closedCaptions ? (danmaku ? "all" : "all,-danmaku") : "danmaku"
        return ["--write-subs", "--sub-langs", languages]
    }
}

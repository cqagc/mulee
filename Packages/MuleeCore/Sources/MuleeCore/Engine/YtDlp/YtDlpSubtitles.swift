/// Bilibili 字幕选择。弹幕保留原始 XML，暂不转换 ASS。
public struct YtDlpSubtitles: Sendable {
    public var danmaku: Bool
    public var closedCaptions: Bool

    public init(danmaku: Bool = false, closedCaptions: Bool = false) {
        self.danmaku = danmaku
        self.closedCaptions = closedCaptions
    }

    public var arguments: [String] {
        guard danmaku || closedCaptions else { return [] }
        // TODO: 弹幕 XML 转 ASS。
        let languages = closedCaptions ? (danmaku ? "all" : "all,-danmaku") : "danmaku"
        return ["--write-subs", "--sub-langs", languages]
    }
}

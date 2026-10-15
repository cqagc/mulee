// 轨道分配思路参考 m13253/danmaku2ass（GPLv3），以 Swift 独立实现。
// https://github.com/m13253/danmaku2ass/blob/master/danmaku2ass.py
import CoreText
import Foundation

/// 每个实例归属一次转换；所有模式共用占用表，避免模式间互相覆盖。
public struct DanmakuASSWriter: Sendable {
    private let width: Int
    private let height: Int
    private let scale: Double
    private let scrollingDuration: Double
    private let fixedDuration: Double
    private var occupiedUntil: [Double]

    public init(videoSize: CGSize? = nil, scrollingDuration: Double = 8, fixedDuration: Double = 5) {
        let size = videoSize ?? CGSize(width: 1920, height: 1080)
        let valid = size.width.isFinite && size.height.isFinite
            && size.width >= 1 && size.height >= 1 && size.width <= 32_768 && size.height <= 32_768
        width = valid ? Int(size.width.rounded()) : 1920
        height = valid ? Int(size.height.rounded()) : 1080
        scale = Double(height) / 576
        self.scrollingDuration = scrollingDuration.isFinite && scrollingDuration > 0 ? scrollingDuration : 8
        self.fixedDuration = fixedDuration.isFinite && fixedDuration > 0 ? fixedDuration : 5
        occupiedUntil = Array(repeating: 0, count: height)
    }

    public var header: String {
        """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        WrapStyle: 2
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Danmaku,PingFang SC,\(Int((25 * scale).rounded())),&H33FFFFFF,&H33FFFFFF,&H33000000,&H33000000,0,0,0,0,100,100,0,0,1,\(outline),0,7,0,0,0,1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
    }

    /// 调用方按时间排序。完整存续期内保留整段竖直轨道，长短文字也不会追尾。
    /// 所有轨道占满时返回 nil；不使用强制覆盖轨道的回退。
    public mutating func dialogue(for comment: DanmakuComment) -> String? {
        guard (1...6).contains(comment.mode), comment.time.isFinite, comment.time >= 0,
              comment.time < 3_600_000_000, comment.fontSize.isFinite,
              comment.fontSize > 0, comment.fontSize <= 1000, !comment.text.isEmpty else { return nil }
        let fontSize = max(1, Int((comment.fontSize * scale).rounded()))
        let lines = comment.text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n")
        let font = CTFontCreateWithName("PingFang SC" as CFString, CGFloat(fontSize), nil)
        let lineHeight = Int(ceil(max(
            Double(fontSize) * 1.4,
            CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)
        )))
        let extent = lineHeight * lines.count + outline * 2 + 4
        guard extent <= height else { return nil }
        let candidates = comment.mode == 4
            ? Array(stride(from: height - extent, through: 0, by: -1))
            : Array(0...(height - extent))
        guard let row = candidates.first(where: { row in
            occupiedUntil[row..<(row + extent)].allSatisfy { $0 <= comment.time }
        }) else { return nil }
        let duration = [4, 5].contains(comment.mode) ? fixedDuration : scrollingDuration
        // 与 ASS 百分秒时间一致；向外取整，避免相邻事件因舍入重叠。
        let start = floor(comment.time * 100) / 100
        let end = ceil((comment.time + duration) * 100) / 100
        guard occupiedUntil[row..<(row + extent)].allSatisfy({ $0 <= start }) else { return nil }
        for index in row..<(row + extent) { occupiedUntil[index] = end }
        let y = row + outline + 2
        let position: String
        if [4, 5].contains(comment.mode) {
            position = "\\an8\\pos(\(width / 2),\(y))"
        } else {
            let textWidth = Int(ceil(lines.map { line in
                let attributed = NSAttributedString(
                    string: line, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
                )
                let rendered = CTLineCreateWithAttributedString(attributed as CFAttributedString)
                let advance = CTLineGetTypographicBounds(rendered, nil, nil, nil)
                let bounds = CTLineGetBoundsWithOptions(rendered, [.useGlyphPathBounds])
                return max(advance, bounds.maxX) + Double(outline * 2 + 4)
            }.max() ?? 0))
            let left = -textWidth
            let right = width + outline + 2
            position = comment.mode == 6
                ? "\\an7\\move(\(left),\(y),\(right),\(y))"
                : "\\an7\\move(\(right),\(y),\(left),\(y))"
        }
        let red = Double((comment.color >> 16) & 0xFF)
        let green = Double((comment.color >> 8) & 0xFF)
        let blue = Double(comment.color & 0xFF)
        let border = 0.2126 * red + 0.7152 * green + 0.0722 * blue < 96 ? "FFFFFF" : "000000"
        let tags = "\(position)\\fs\(fontSize)\\c\(Self.assColor(comment.color))\\3c&H\(border)&\\alpha&H33&"
        return "Dialogue: 0,\(Self.timestamp(start)),\(Self.timestamp(end)),Danmaku,,0,0,0,,{\(tags)}\(Self.escape(comment.text))\n"
    }

    public static func assColor(_ rgb: UInt32) -> String {
        let bgr = ((rgb & 0xFF) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 0xFF)
        let hex = String(bgr, radix: 16, uppercase: true)
        return "&H" + String(repeating: "0", count: max(0, 6 - hex.count)) + hex + "&"
    }

    public static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            // ASS 没有通用的反斜线转义；零宽分隔符防止 \N / \h 被解释为控制符。
            .replacingOccurrences(of: "\\", with: "\\\u{200B}")
            .replacingOccurrences(of: "{", with: "\\{")
            .replacingOccurrences(of: "}", with: "\\}")
            .replacingOccurrences(of: "\n", with: "\\N")
    }

    private var outline: Int { max(1, Int(ceil(scale))) }

    private static func timestamp(_ time: Double) -> String {
        let centiseconds = Int((time * 100).rounded())
        func padded(_ value: Int) -> String { value < 10 ? "0\(value)" : String(value) }
        return "\(centiseconds / 360_000):\(padded(centiseconds / 6000 % 60)):\(padded(centiseconds / 100 % 60)).\(padded(centiseconds % 100))"
    }
}

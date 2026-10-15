import Foundation

/// 可渲染的普通弹幕；ordinal 保证同一时间的原始顺序。
public struct DanmakuComment: Codable, Sendable {
    public let time: Double
    public let mode: Int
    public let fontSize: Double
    public let color: UInt32
    public let text: String
    let ordinal: Int

    public init(time: Double, mode: Int, fontSize: Double, color: UInt32, text: String, ordinal: Int = 0) {
        self.time = time
        self.mode = mode
        self.fontSize = fontSize
        self.color = color
        self.text = text
        self.ordinal = ordinal
    }
}

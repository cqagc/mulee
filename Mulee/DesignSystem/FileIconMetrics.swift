import SwiftUI

/// 64pt 母版等比缩放；小尺寸单独调整虚线节奏，避免变成点线或实线。
struct FileIconMetrics {
    let size: CGFloat

    var scale: CGFloat { size / 64 }
    var side: CGFloat { 50 * scale }
    var cornerRadius: CGFloat { 13 * scale }
    var lineWidth: CGFloat { 2.5 * scale }
    var glyphSize: CGFloat { side * 0.45 }

    var dash: [CGFloat] {
        if size <= 16 { return [1.5, 1.25].map { $0 * size / 16 } }
        if size <= 32 { return [2.5, 2].map { $0 * size / 32 } }
        return [4.5, 3.5].map { $0 * scale }
    }

    var strokeStyle: StrokeStyle {
        StrokeStyle(lineWidth: lineWidth, lineCap: .butt, lineJoin: .round, dash: dash)
    }
}

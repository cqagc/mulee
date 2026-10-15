import AppKit
import SwiftUI

/// 1b 配方：状态内只改变色相；中性类别将色度乘以 0.15。
struct FileIconPalette {
    let category: FileCategory
    let state: FileIconState
    let colorScheme: ColorScheme

    private var hue: Double {
        if state.isEngineUnavailable { return 255 }
        return state.needsAttention ? 75 : category.hue ?? 255
    }
    private var chromaScale: Double {
        if state.isEngineUnavailable { return 0.15 }
        return state.needsAttention || category.hue != nil ? 1 : 0.15
    }

    var stroke: Color { color(light: 0.70, dark: 0.60, chroma: 0.11) }
    var background: Color { color(light: 0.975, dark: 0.27, chroma: 0.015) }
    var progress: Color { color(light: 0.89, dark: 0.40, chroma: 0.07) }
    var glyph: Color { color(light: 0.55, dark: 0.80, chroma: 0.13) }
    var completed: Color { color(light: 0.60, dark: 0.66, chroma: 0.17) }
    var completedBadge: Color { color(light: 0.48, dark: 0.52, chroma: 0.17) }
    var canvas: Color { resolved(.windowBackgroundColor) }

    private func color(light: Double, dark: Double, chroma: Double) -> Color {
        let dynamic = OKLCHColor.dynamic(
            light: OKLCHColor(lightness: light, chroma: chroma * chromaScale, hue: hue),
            dark: OKLCHColor(lightness: dark, chroma: chroma * chromaScale, hue: hue)
        )
        // 显式解析环境外观，保证同一总览窗口内的左右两半各自正确取色。
        return resolved(dynamic)
    }

    private func resolved(_ color: NSColor) -> Color {
        let appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        return Color(nsColor: appearance.map { OKLCHColor.resolve(color, appearance: $0) } ?? color)
    }
}

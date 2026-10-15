import AppKit

/// OKLCH → OKLab → 线性 sRGB → sRGB；超色域分量裁剪到 0...1。
struct OKLCHColor: Sendable {
    let lightness: Double
    let chroma: Double
    let hue: Double

    nonisolated var components: (red: Double, green: Double, blue: Double) {
        let angle = hue * .pi / 180
        let a = chroma * cos(angle)
        let b = chroma * sin(angle)
        let l = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (
            Self.encode(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
            Self.encode(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
            Self.encode(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        )
    }

    nonisolated var nsColor: NSColor {
        let rgb = components
        return NSColor(srgbRed: rgb.red, green: rgb.green, blue: rgb.blue, alpha: 1)
    }

    static func dynamic(light: OKLCHColor, dark: OKLCHColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark.nsColor : light.nsColor
        }
    }

    static func resolve(_ color: NSColor, appearance: NSAppearance) -> NSColor {
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        return resolved
    }

    nonisolated private static func encode(_ linear: Double) -> Double {
        let encoded = linear <= 0.0031308 ? 12.92 * linear : 1.055 * pow(linear, 1 / 2.4) - 0.055
        return min(1, max(0, encoded))
    }
}

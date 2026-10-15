import AppKit
import Testing
@testable import Mulee

@MainActor
@Suite struct OKLCHColorTests {
    @Test(arguments: [
        (0.60, 0.17, 255.0, 42.0, 127.0, 226.0),
        (0.72, 0.12, 75.0, 208.0, 152.0, 68.0)
    ])
    func referenceColors(_ lightness: Double, _ chroma: Double, _ hue: Double,
                         _ red: Double, _ green: Double, _ blue: Double) {
        let rgb = OKLCHColor(lightness: lightness, chroma: chroma, hue: hue).components
        #expect(abs(rgb.red - red / 255) <= 1 / 255)
        #expect(abs(rgb.green - green / 255) <= 1 / 255)
        #expect(abs(rgb.blue - blue / 255) <= 1 / 255)
    }

    @Test(arguments: [0.0, 0.5, 1.0], [
        (0.0, 0.0), (0.17, 75.0), (0.17, 255.0), (1.0, 0.0), (1.0, 75.0), (1.0, 255.0), (1.0, 340.0)
    ])
    func gamutClipping(_ lightness: Double, _ chromaAndHue: (Double, Double)) {
        let (chroma, hue) = chromaAndHue
        let rgb = OKLCHColor(lightness: lightness, chroma: chroma, hue: hue).components
        #expect((0...1).contains(rgb.red))
        #expect((0...1).contains(rgb.green))
        #expect((0...1).contains(rgb.blue))
    }

    @Test func dynamicAppearance() throws {
        let light = OKLCHColor(lightness: 0.70, chroma: 0.11, hue: 255)
        let dark = OKLCHColor(lightness: 0.60, chroma: 0.11, hue: 255)
        let color = OKLCHColor.dynamic(light: light, dark: dark)
        let aqua = try #require(NSAppearance(named: .aqua))
        let darkAqua = try #require(NSAppearance(named: .darkAqua))
        let lightRGB = try #require(OKLCHColor.resolve(color, appearance: aqua).usingColorSpace(.sRGB))
        let darkRGB = try #require(OKLCHColor.resolve(color, appearance: darkAqua).usingColorSpace(.sRGB))
        #expect(abs(lightRGB.redComponent - light.components.red) < 0.0001)
        #expect(abs(lightRGB.greenComponent - light.components.green) < 0.0001)
        #expect(abs(lightRGB.blueComponent - light.components.blue) < 0.0001)
        #expect(abs(darkRGB.redComponent - dark.components.red) < 0.0001)
        #expect(abs(darkRGB.greenComponent - dark.components.green) < 0.0001)
        #expect(abs(darkRGB.blueComponent - dark.components.blue) < 0.0001)
    }
}

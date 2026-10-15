import AppKit
import Testing
@testable import Mulee

/// 保证 Design/ICONS.md 里规定的每个 SF Symbol 在当前系统上真实存在。
@Suite struct MuleeSymbolTests {
    @Test(arguments: MuleeSymbol.allCases)
    func symbolExists(_ symbol: MuleeSymbol) {
        #expect(NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil) != nil, "SF Symbol 不存在：\(symbol.name)")
    }

    @Test func symbolNamesAreUnique() {
        let names = MuleeSymbol.allCases.map(\.name)
        #expect(Set(names).count == names.count)
    }
}

import SwiftUI

/// 菜单栏弹出面板。占位实现，由对应功能的工人按原型替换。
struct MenuBarPanelView: View {
    var body: some View {
        ContentUnavailableView("菜单栏弹出面板", systemImage: MuleeSymbol.all.name)
    }
}

#Preview {
    MenuBarPanelView()
        .environment(AppModel())
}

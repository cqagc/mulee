import SwiftUI

/// 设置窗口。占位实现，由对应功能的工人按原型替换。
struct SettingsView: View {
    var body: some View {
        ContentUnavailableView("设置窗口", systemImage: MuleeSymbol.all.name)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}

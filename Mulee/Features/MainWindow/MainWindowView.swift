import SwiftUI

/// 主窗口（侧边栏 + 任务列表 + 详情栏）。占位实现，由对应功能的工人按原型替换。
struct MainWindowView: View {
    var body: some View {
        ContentUnavailableView("主窗口（侧边栏 + 任务列表 + 详情栏）", systemImage: MuleeSymbol.all.name)
    }
}

#Preview {
    MainWindowView()
        .environment(AppModel())
}

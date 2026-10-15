import SwiftUI

/// 新建下载面板。占位实现，由对应功能的工人按原型替换。
struct NewTaskSheet: View {
    var body: some View {
        ContentUnavailableView("新建下载面板", systemImage: MuleeSymbol.all.name)
    }
}

#Preview {
    NewTaskSheet()
        .environment(AppModel())
}

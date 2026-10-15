import SwiftUI

struct MainSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        List(selection: $selection) {
            Section("下载") {
                ForEach(SidebarItem.downloads) { item in
                    HStack {
                        Label(item.title, systemImage: item.symbol.name)
                        Spacer()
                        Text(item.filter(model.tasks).count, format: .number)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .tag(item)
                }
            }
            Section("类型") {
                ForEach(SidebarItem.kinds) { item in
                    Label(item.title, systemImage: item.symbol.name)
                        .tag(item)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            NetworkStatusView(status: model.networkStatus)
        }
    }
}

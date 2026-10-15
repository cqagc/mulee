import SwiftUI

struct MainSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        let counts = SidebarItem.counts(in: model.tasks)

        List(selection: $selection) {
            Section("下载") {
                ForEach(SidebarItem.downloads) { item in
                    HStack {
                        Label(item.title, systemImage: item.symbol.name)
                        Spacer()
                        Text(counts[item, default: 0], format: .number)
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
            VStack(alignment: .leading) {
                if model.isScheduledLimitActive {
                    Text("计划限速中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                NetworkStatusView(status: model.networkStatus)
            }
        }
    }
}

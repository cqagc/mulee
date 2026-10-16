import SwiftUI

struct MainSidebarView: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: SidebarItem?

    var body: some View {
        let counts = SidebarItem.counts(in: model.tasks)

        VStack(spacing: 0) {
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
                Section("智能列表") {
                    ForEach(SidebarItem.smartLists) { item in
                        Label(item.title, systemImage: item.symbol.name)
                            .badge(counts[item, default: 0])
                            .tag(item)
                    }
                    ForEach(counts.keys.compactMap { item -> String? in
                        if case .tag(let name) = item { return name }
                        return nil
                    }.sorted(), id: \.self) { name in
                        Label(name, systemImage: MuleeSymbol.tags.name)
                            .badge(counts[.tag(name), default: 0])
                            .tag(SidebarItem.tag(name))
                    }
                }
                Section {
                    Label(SidebarItem.recentlyDeleted.title, systemImage: MuleeSymbol.delete.name)
                        .badge(counts[.recentlyDeleted, default: 0])
                        .tag(SidebarItem.recentlyDeleted)
                }
                Section("类型") {
                    ForEach(SidebarItem.kinds) { item in
                        Label(item.title, systemImage: item.symbol.name)
                            .tag(item)
                    }
                }
            }
            .listStyle(.sidebar)

            VStack(alignment: .leading) {
                if model.isScheduledLimitActive {
                    Text("计划限速中")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                NetworkStatusView(status: model.networkStatus)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

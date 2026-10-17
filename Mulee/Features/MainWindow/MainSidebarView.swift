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
            // 侧边栏由 AppKit 的 sidebar 分栏项承载时，SwiftUI 会按旧式毛玻璃侧边栏传入 backgroundMaterial，
            // 让列表按 vibrancy 绘制；macOS 26 的侧边栏是玻璃容器，没有可混合的材质，传统滚动条滑块会画成深色实心块。
            // NavigationSplitView 里这个值为空，这里对齐它。
            .environment(\.backgroundMaterial, nil)

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

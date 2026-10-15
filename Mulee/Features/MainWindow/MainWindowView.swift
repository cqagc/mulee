import SwiftUI

/// 主窗口：原生侧边栏、任务列表和可收起的详情栏。
struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: SidebarItem? = .all
    @State private var search = ""
    @State private var isShowingInspector = true

    private var category: SidebarItem { selection ?? .all }
    private var canPauseAll: Bool {
        model.tasks.contains { [.downloading, .waitingForSources].contains($0.status) }
    }

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            MainSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(Theme.sidebarWidth)
        } detail: {
            TaskListView(tasks: category.filter(model.tasks, search: search), isSearching: !search.isEmpty)
                .navigationTitle(category.navigationTitle)
                .navigationSubtitle(SidebarItem.subtitle(for: category.filter(model.tasks, search: search)))
                .searchable(text: $search, prompt: "搜索任务")
        }
        .inspector(isPresented: $isShowingInspector) {
            TaskInspectorView(task: model.selectedTask)
                .inspectorColumnWidth(min: Theme.inspectorWidth, ideal: Theme.inspectorWidth, max: 380)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("新建下载", systemImage: MuleeSymbol.add.name, action: showNewTask)
                    .help("新建下载")
                Button(canPauseAll ? "全部暂停" : "全部继续",
                       systemImage: canPauseAll ? MuleeSymbol.pause.name : MuleeSymbol.resume.name,
                       action: toggleAll)
                    .help("全部暂停 / 继续")
                    .disabled(!canPauseAll && !model.tasks.contains { $0.status == .paused })
                TransferSpeedView(downloadRate: model.totalDownloadRate, uploadRate: model.totalUploadRate)
                Button(isShowingInspector ? "隐藏详情栏" : "显示详情栏", systemImage: MuleeSymbol.inspector.name, action: toggleInspector)
                    .help(isShowingInspector ? "隐藏详情栏" : "显示详情栏")
            }
        }
        .sheet(isPresented: $model.isShowingNewTask) {
            NewTaskSheet()
        }
        .onChange(of: selection, clearHiddenSelection)
        .onChange(of: search, clearHiddenSelection)
    }

    private func showNewTask() {
        model.showNewTask()
    }

    private func toggleAll() {
        if canPauseAll {
            model.pauseAll()
        } else {
            model.resumeAll()
        }
    }

    private func toggleInspector() {
        isShowingInspector.toggle()
    }

    private func clearHiddenSelection() {
        if let id = model.selectedTaskID, !category.filter(model.tasks, search: search).contains(where: { $0.id == id }) {
            model.selectedTaskID = nil
        }
    }
}

#Preview {
    MainWindowView()
        .environment(AppModel())
}

#Preview("暗色") {
    MainWindowView()
        .environment(AppModel())
        .preferredColorScheme(.dark)
}

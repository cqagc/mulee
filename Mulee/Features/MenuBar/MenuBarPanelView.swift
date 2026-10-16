import SwiftUI

/// 菜单栏弹出面板：速度、正在下载的任务、粘贴框和底部操作。
struct MenuBarPanelView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let presentation = MenuBarPresentation(tasks: model.tasks)
        VStack(alignment: .leading, spacing: 12) {
            DiskReserveBanner()
            if presentation.isEmpty {
                ContentUnavailableView(
                    "还没有下载任务",
                    systemImage: MuleeSymbol.downloading.name,
                    description: Text("粘贴链接开始下载")
                )
            } else {
                MenuBarSpeedHeader(downloadRate: model.totalDownloadRate, uploadRate: model.totalUploadRate)
                SpeedHistoryChart(samples: model.downloadRateHistory)
                if !presentation.visibleTasks.isEmpty {
                    Text("正在下载 · \(presentation.visibleTasks.count)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                    ForEach(presentation.visibleTasks) { task in
                        MenuBarTaskRow(task: task)
                    }
                }
                MenuBarWaitingNotice(count: presentation.waitingSourceCount)
            }
            MenuBarPasteField()
            Ed2kNetworkStatusView(status: model.networkStatus)
            if model.networkStatus.p2pRoutedThroughProxy {
                NetworkProxyWarningButton()
            }
            Divider()
            MenuBarFooter(pauseResumeAction: presentation.pauseResumeAction)
        }
        .padding(14)
        .frame(width: 340)
    }
}

#Preview {
    MenuBarPanelView()
        .environment(AppModel())
}

import AppIntents

struct MuleeAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NewMuleeDownloadIntent(), phrases: ["用 \(.applicationName) 新建下载"],
            shortTitle: "新建下载", systemImageName: "plus"
        )
        AppShortcut(
            intent: PauseMuleeDownloadsIntent(), phrases: ["暂停 \(.applicationName) 的全部下载"],
            shortTitle: "暂停全部", systemImageName: "pause.fill"
        )
        AppShortcut(
            intent: ResumeMuleeDownloadsIntent(), phrases: ["继续 \(.applicationName) 的全部下载"],
            shortTitle: "继续全部", systemImageName: "play.fill"
        )
        AppShortcut(
            intent: MuleeDownloadStatusIntent(), phrases: ["获取 \(.applicationName) 的下载状态"],
            shortTitle: "下载状态", systemImageName: "arrow.down.circle"
        )
    }
}

import MuleeCore

/// 系统操作前的纯判定，测试无需关闭真实窗口。
enum WindowClosePolicy {
    static func shouldQuit(closeKeepsRunning: Bool, mainWindowCount: Int) -> Bool {
        !closeKeepsRunning && mainWindowCount <= 1
    }

    static func needsConfirmation(tasks: [DownloadTask]) -> Bool {
        tasks.contains { [.downloading, .queued, .waitingForSources, .seeding, .extracting, .postProcessing].contains($0.status) }
    }
}

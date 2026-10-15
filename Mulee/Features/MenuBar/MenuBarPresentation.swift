import Foundation
import MuleeCore

/// 菜单栏面板的展示逻辑，视图只负责排版。
struct MenuBarPresentation {
    /// 「正在下载」区域最多显示的任务数。
    static let maxVisibleTasks = 4

    /// 「全部暂停 / 全部继续」按钮的状态。
    enum PauseResumeAction: Equatable {
        case pauseAll
        case resumeAll
    }

    let tasks: [DownloadTask]

    /// 「正在下载」里显示的任务：下载中、合并中、解压中，最多 4 个。
    var visibleTasks: [DownloadTask] {
        Array(tasks.filter { Self.activeStatuses.contains($0.status) }.prefix(Self.maxVisibleTasks))
    }

    /// 在等待来源的电驴任务数。
    var waitingSourceCount: Int {
        tasks.count { $0.status == .waitingForSources }
    }

    /// 有已暂停任务时显示「全部继续」，否则显示「全部暂停」。
    var pauseResumeAction: PauseResumeAction {
        tasks.contains { $0.status == .paused } ? .resumeAll : .pauseAll
    }

    /// 没有任何任务时显示空状态。
    var isEmpty: Bool {
        tasks.isEmpty
    }

    /// 任务行右侧文字：下载中显示速度，其余显示阶段。
    static func trailingText(for task: DownloadTask) -> String {
        switch task.status {
        case .postProcessing:
            "合并中"
        case .extracting:
            "解压中"
        default:
            speedText(task.downloadRate)
        }
    }

    /// 速度文字，例如「11.2 MB/s」。
    static func speedText(_ bytesPerSecond: Int64) -> String {
        "\(bytesPerSecond.formatted(.byteCount(style: .file)))/s"
    }

    private static let activeStatuses: Set<TaskStatus> = [.downloading, .postProcessing, .extracting]
}

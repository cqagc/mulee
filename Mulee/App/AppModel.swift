import Foundation
import MuleeCore
import Observation

/// 全局 UI 状态。引擎接入前用 MockData 填充。
@Observable
final class AppModel {
    var tasks: [DownloadTask]
    var networkStatus: NetworkStatus
    var unzipRules: [UnzipRule]
    /// 主窗口当前选中的任务。
    var selectedTaskID: DownloadTask.ID?
    /// 是否显示「新建下载」面板。
    var isShowingNewTask = false

    init(
        tasks: [DownloadTask] = MockData.tasks,
        networkStatus: NetworkStatus = MockData.healthyNetwork,
        unzipRules: [UnzipRule] = MockData.unzipRules
    ) {
        self.tasks = tasks
        self.networkStatus = networkStatus
        self.unzipRules = unzipRules
        self.selectedTaskID = MockData.longTailTask.id
    }

    var selectedTask: DownloadTask? {
        tasks.first { $0.id == selectedTaskID }
    }

    /// 所有任务的下载速度之和（字节/秒）。
    var totalDownloadRate: Int64 {
        tasks.reduce(0) { $0 + $1.downloadRate }
    }

    /// 所有任务的上传速度之和（字节/秒）。
    var totalUploadRate: Int64 {
        tasks.reduce(0) { $0 + $1.uploadRate }
    }
}

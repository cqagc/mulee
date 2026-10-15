import Foundation
import MuleeCore
import Observation

/// 全局 UI 状态。引擎接入前用 MockData 填充，所有操作只改内存里的示例数据。
@Observable
final class AppModel {
    var tasks: [DownloadTask]
    var networkStatus: NetworkStatus
    var unzipRules: [UnzipRule]
    /// 主窗口当前选中的任务。
    var selectedTaskID: DownloadTask.ID?
    /// 是否显示「新建下载」面板。
    var isShowingNewTask = false
    /// 打开「新建下载」面板时预填的文本（例如菜单栏里粘贴的链接）。读取后由面板清空。
    var pendingNewTaskText = ""
    /// 最近 30 次采样的总下载速度（字节/秒），最后一个是最新值。菜单栏速度曲线使用。
    var downloadRateHistory: [Int64]

    init(
        tasks: [DownloadTask] = MockData.tasks,
        networkStatus: NetworkStatus = MockData.healthyNetwork,
        unzipRules: [UnzipRule] = MockData.unzipRules
    ) {
        self.tasks = tasks
        self.networkStatus = networkStatus
        self.unzipRules = unzipRules
        self.selectedTaskID = MockData.longTailTask.id
        let current = tasks.reduce(0) { $0 + $1.downloadRate }
        // 示例曲线：从三成速度逐步爬升到当前速度。
        self.downloadRateHistory = (0..<30).map { index in
            Int64(Double(current) * (0.3 + 0.7 * Double(index) / 29))
        }
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

    /// 是否有任务在传输数据（决定是否阻止系统睡眠）。
    var hasActiveTransfers: Bool {
        tasks.contains { [.downloading, .seeding, .extracting, .postProcessing].contains($0.status) }
    }

    /// 打开「新建下载」面板，可选预填文本。
    func showNewTask(prefill text: String = "") {
        pendingNewTaskText = text
        isShowingNewTask = true
    }

    /// 暂停所有未完成的任务。
    func pauseAll() {
        for index in tasks.indices where [.downloading, .waitingForSources].contains(tasks[index].status) {
            pause(at: index)
        }
    }

    /// 继续所有暂停的任务。
    func resumeAll() {
        for index in tasks.indices where tasks[index].status == .paused {
            resume(at: index)
        }
    }

    func pause(_ id: DownloadTask.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        pause(at: index)
    }

    func resume(_ id: DownloadTask.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        resume(at: index)
    }

    func remove(_ id: DownloadTask.ID) {
        tasks.removeAll { $0.id == id }
        if selectedTaskID == id {
            selectedTaskID = nil
        }
    }

    /// 根据识别出的链接创建任务（示例实现：只加入列表，不真正下载）。
    func addTasks(from links: [ParsedLink], autoExtract: Bool) {
        let newTasks = links.map { DownloadTask(link: $0, autoExtract: autoExtract) }
        tasks.insert(contentsOf: newTasks, at: 0)
        selectedTaskID = newTasks.first?.id ?? selectedTaskID
    }

    private func pause(at index: Int) {
        tasks[index].status = .paused
        tasks[index].downloadRate = 0
    }

    private func resume(at index: Int) {
        if case .ed2k = tasks[index].detail {
            tasks[index].status = .waitingForSources
        } else {
            tasks[index].status = .downloading
        }
    }
}

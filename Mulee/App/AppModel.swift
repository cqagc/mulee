import Foundation
import MuleeCore
import Observation

/// 全局 UI 状态。默认示例数据供预览使用，正式启动显式传入空列表。
@MainActor
@Observable
final class AppModel {
    var tasks: [DownloadTask] {
        didSet { updateSleepPrevention() }
    }
    var preventsSleepWhileDownloading: Bool {
        didSet { updateSleepPrevention() }
    }
    var networkStatus: NetworkStatus
    var engineStates: [TaskKind: EngineState] = Dictionary(uniqueKeysWithValues: TaskKind.allCases.map { ($0, .unavailable) })
    @ObservationIgnored weak var coordinator: DownloadCoordinator?
    var unzipRules: [UnzipRule]
    /// 主窗口当前选中的任务。
    var selectedTaskID: DownloadTask.ID?
    /// 是否显示「新建下载」面板。
    var isShowingNewTask = false
    /// 打开「新建下载」面板时预填的文本（例如菜单栏里粘贴的链接）。读取后由面板清空。
    var pendingNewTaskText = ""
    /// 最近 30 次采样的总下载速度（字节/秒），最后一个是最新值。菜单栏速度曲线使用。
    var downloadRateHistory: [Int64]
    /// 有任务在传输时阻止系统空闲睡眠。
    @ObservationIgnored private let sleepPreventer: SleepPreventer

    init(
        tasks: [DownloadTask] = MockData.tasks,
        networkStatus: NetworkStatus = MockData.healthyNetwork,
        unzipRules: [UnzipRule] = MockData.unzipRules,
        preventsSleepWhileDownloading: Bool = true,
        sleepPreventer: SleepPreventer = SleepPreventer()
    ) {
        self.sleepPreventer = sleepPreventer
        self.tasks = tasks
        self.preventsSleepWhileDownloading = preventsSleepWhileDownloading
        self.networkStatus = networkStatus
        self.unzipRules = unzipRules
        self.selectedTaskID = tasks.first { $0.id == MockData.longTailTask.id }?.id ?? tasks.first?.id
        let current = tasks.reduce(0) { $0 + $1.downloadRate }
        // 示例曲线：从三成速度逐步爬升到当前速度。
        self.downloadRateHistory = (0..<30).map { index in
            Int64(Double(current) * (0.3 + 0.7 * Double(index) / 29))
        }
        updateSleepPrevention()
    }

    /// 是否正在阻止系统睡眠（菜单栏底部提示用）。
    var isPreventingSleep: Bool {
        sleepPreventer.isPreventingSleep
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
        for task in tasks where [.downloading, .waitingForSources, .queued].contains(task.status) {
            pause(task.id)
        }
    }

    /// 继续所有暂停的任务。
    func resumeAll() {
        for task in tasks where task.status == .paused {
            resume(task.id)
        }
    }

    func pause(_ id: DownloadTask.ID) {
        if let coordinator {
            Task { await coordinator.pause(id) }
            return
        }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        pause(at: index)
    }

    func resume(_ id: DownloadTask.ID) {
        if let coordinator {
            Task { await coordinator.resume(id) }
            return
        }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        resume(at: index)
    }

    func remove(_ id: DownloadTask.ID) {
        if let coordinator {
            Task { await coordinator.remove(id) }
            return
        }
        tasks.removeAll { $0.id == id }
        if selectedTaskID == id {
            selectedTaskID = nil
        }
    }

    /// 正式运行交给协调器；没有协调器时保留预览和测试的示例行为。
    func addTasks(from links: [ParsedLink], autoExtract: Bool, directory: URL? = nil) {
        if let coordinator {
            Task { await coordinator.add(links: links, autoExtract: autoExtract, directory: directory) }
            return
        }
        let newTasks = links.map { DownloadTask(link: $0, autoExtract: autoExtract) }
        tasks.insert(contentsOf: newTasks, at: 0)
        selectedTaskID = newTasks.first?.id ?? selectedTaskID
    }

    private func updateSleepPrevention() {
        sleepPreventer.update(isActive: preventsSleepWhileDownloading && hasActiveTransfers)
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

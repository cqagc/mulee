import Foundation
import MuleeCore
import Observation

/// 全局 UI 状态。默认示例数据供预览使用，正式启动显式传入空列表。
@MainActor
@Observable
final class AppModel {
    var tasks: [DownloadTask] {
        didSet {
            extractionCoordinator?.tasksDidChange()
            updateSleepPrevention()
            notificationService?.tasksDidChange()
            whenAllDoneController?.refresh()
            historyStore?.scheduleSave(tasks: tasks) { [weak self] issue in
                self?.taskHistoryIssue = issue
            }
        }
    }
    var preventsSleepWhileDownloading: Bool {
        didSet { updateSleepPrevention() }
    }
    var allowsSleepWhenDone = true {
        didSet { updateSleepPrevention() }
    }
    var isScheduledLimitActive = false
    var isSlowModeActive = false
    var slowModeReason: String?
    var diskReserveWarnings: [DiskReserveMonitor.Warning] = []
    var notificationPermissionDenied = false
    var whenAllDoneAction: WhenAllDoneAction = .none
    var whenAllDoneSecondsRemaining: Int?
    var isPerformingWhenAllDone = false
    @ObservationIgnored var userPausedTaskIDs: Set<DownloadTask.ID> = []
    @ObservationIgnored weak var diskReserveMonitor: DiskReserveMonitor?
    @ObservationIgnored weak var notificationService: NotificationService?
    @ObservationIgnored weak var whenAllDoneController: WhenAllDoneController?
    @ObservationIgnored weak var slowModeController: SlowModeController?
    @ObservationIgnored var downloadSettings: SettingsModel?
    var mainWindowRequest = 0
    @ObservationIgnored weak var settingsRuntime: SettingsRuntime?
    var bitTorrent: BitTorrentController?
    var publicTrackers: PublicTrackerController?
    var ed2k: Ed2kController?
    var networkStatus: NetworkStatus
    var engineStates: [TaskKind: EngineState] = Dictionary(uniqueKeysWithValues: TaskKind.allCases.map { ($0, .unavailable) })
    /// 历史读取、备份或写入异常；独立于引擎启停，避免启动成功后覆盖诊断。
    var taskHistoryIssue: String?
    @ObservationIgnored private var historyStore: TaskHistoryStore?
    @ObservationIgnored private(set) var excludedVideoTaskIDs: Set<String> = []
    @ObservationIgnored weak var coordinator: DownloadCoordinator?
    @ObservationIgnored weak var extractionCoordinator: ExtractionCoordinator?
    @ObservationIgnored var unzipRuleStore: UnzipRuleStore?
    @ObservationIgnored var extractionPasswords: any ExtractionPasswordStoring = KeychainPasswordProvider()
    @ObservationIgnored var pagePasswords: [DownloadTask.ID: String] = [:]
    var unzipRuleIssue: String?
    var unzipRules: [UnzipRule] {
        didSet { persistUnzipRules() }
    }
    /// 主窗口当前选中的任务。
    var selectedTaskID: DownloadTask.ID?
    /// 是否显示「新建下载」面板。
    var isShowingNewTask = false
    var openURLIssue: String?
    /// 打开「新建下载」面板时预填的文本，读取后由面板清空。
    var pendingNewTaskText = ""
    var pendingNewTaskContexts: [ParsedLink: NewTaskContext] = [:]
    var waitingHTTPReplacement: HTTPReplacementWait?
    var pendingBrowserHTTPReplacement: BrowserHTTPReplacement?
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
        let current = tasks.reduce(0) { $0 + ($1.deletedAt == nil ? $1.downloadRate : 0) }
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

    var activeTasks: [DownloadTask] { tasks.filter { $0.deletedAt == nil } }

    /// 所有任务的下载速度之和（字节/秒）。
    var totalDownloadRate: Int64 {
        tasks.reduce(0) { $0 + ($1.deletedAt == nil ? $1.downloadRate : 0) }
    }

    /// 所有任务的上传速度之和（字节/秒）。
    var totalUploadRate: Int64 {
        tasks.reduce(0) { $0 + ($1.deletedAt == nil ? $1.uploadRate : 0) }
    }

    /// 是否有任务在传输或后处理；睡眠判定还会结合完成后允许睡眠的偏好。
    var hasActiveTransfers: Bool {
        tasks.contains { $0.deletedAt == nil && [.downloading, .seeding, .extracting, .postProcessing].contains($0.status) }
    }

    /// 打开「新建下载」面板，可选预填文本。
    func showNewTask(prefill text: String = "") {
        whenAllDoneController?.userDidInteract()
        mainWindowRequest += 1
        if !text.isEmpty {
            let separator = pendingNewTaskText.isEmpty || pendingNewTaskText.hasSuffix("\n") ? "" : "\n"
            pendingNewTaskText += separator + text
        }
        isShowingNewTask = true
    }

    /// 暂停所有未完成的任务。
    func pauseAll() {
        for task in tasks where task.deletedAt == nil && [.downloading, .waitingForSources, .queued, .seeding].contains(task.status) {
            pause(task.id)
        }
    }

    /// 继续所有暂停的任务。
    func resumeAll() {
        for task in tasks where task.deletedAt == nil && task.status == .paused {
            resume(task.id)
        }
    }

    func pause(_ id: DownloadTask.ID) {
        guard tasks.contains(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        userPausedTaskIDs.insert(id)
        whenAllDoneController?.userDidInteract()
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].pauseReason = nil
        }
        if let coordinator {
            Task { await coordinator.pause(id) }
            return
        }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        pause(at: index)
    }

    func resume(_ id: DownloadTask.ID) {
        guard tasks.contains(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        userPausedTaskIDs.remove(id)
        whenAllDoneController?.userDidInteract()
        if let index = tasks.firstIndex(where: { $0.id == id }) {
            tasks[index].pauseReason = nil
        }
        if let coordinator {
            Task { await coordinator.resume(id) }
            return
        }
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        resume(at: index)
    }

    func remove(_ id: DownloadTask.ID) {
        whenAllDoneController?.userDidInteract()
        guard let task = tasks.first(where: { $0.id == id }), task.deletedAt == nil else { return }
        if [.bittorrent, .ed2k].contains(task.kind), coordinator != nil {
            BitTorrentRemoval.confirm(task: task, model: self)
        } else if task.status == .completed {
            if task.kind == .video, let coordinator {
                coordinator.removeCompletedVideo(task)
            } else {
                coordinator?.excludeFromSnapshots(task)
                trashRecord(id)
            }
        } else if let coordinator {
            Task { await coordinator.remove(id) }
        } else {
            trashRecord(id)
        }
    }

    func trashRecord(_ id: DownloadTask.ID, now: Date = .now) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].deletedAt == nil else { return }
        userPausedTaskIDs.remove(id)
        var task = tasks[index]
        TaskTrash.move(&task, now: now)
        tasks[index] = task
        if selectedTaskID == id { selectedTaskID = nil }
    }

    func restoreRecord(_ id: DownloadTask.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == id && $0.deletedAt != nil }) else { return }
        var task = tasks[index]
        task.deletedAt = nil
        // 恢复记录不隐式重新下载或写盘。
        if task.completedAt != nil || [.completed, .seeding].contains(task.status) {
            task.status = .completed
        } else if task.status != .failed {
            task.status = .paused
        }
        // HTTP 成品仍可能存在于引擎会话，保留标识避免重启时重复导入。
        if task.kind != .http || task.status != .completed { task.engineTaskID = nil }
        tasks[index] = task
    }

    func purgeExpiredTrash(now: Date = .now) {
        let expired = tasks.filter { TaskTrash.isExpired($0, now: now) }
        guard !expired.isEmpty else { return }
        let ids = Set(expired.map(\.id))
        tasks.removeAll { ids.contains($0.id) }
        if let selectedTaskID, ids.contains(selectedTaskID) { self.selectedTaskID = nil }
    }

    func refreshTrackedFile(_ id: DownloadTask.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }),
              tasks[index].completedAt != nil || [.completed, .seeding].contains(tasks[index].status) else { return }
        var task = tasks[index]
        FileTracker.resolve(&task)
        if task != tasks[index] { tasks[index] = task }
    }

    func setTags(_ id: DownloadTask.ID, text: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        var seen: Set<String> = []
        tasks[index].tags = text.components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    func removeRecord(_ id: DownloadTask.ID) {
        userPausedTaskIDs.remove(id)
        tasks.removeAll { $0.id == id }
        if selectedTaskID == id {
            selectedTaskID = nil
        }
    }

    var hasCompletedTasks: Bool {
        tasks.contains { $0.deletedAt == nil && $0.status == .completed }
    }

    /// 只清理记录，不触碰已经下载的文件。
    func clearCompletedTasks() {
        let completed = tasks.filter { $0.deletedAt == nil && $0.status == .completed }
        if let coordinator {
            for task in completed where ![.bittorrent, .ed2k].contains(task.kind) {
                if task.kind == .video {
                    coordinator.removeCompletedVideo(task)
                } else {
                    coordinator.excludeFromSnapshots(task)
                    trashRecord(task.id)
                }
            }
            Task {
                for task in completed where [.bittorrent, .ed2k].contains(task.kind) {
                    await coordinator.remove(task.id, deleteFiles: false)
                }
            }
        } else {
            for task in completed { trashRecord(task.id) }
        }
    }

    func loadTaskHistory(from store: TaskHistoryStore) {
        let result = store.load()
        taskHistoryIssue = result.issue
        historyStore = store
        let exclusions = store.fileURL.deletingLastPathComponent().appending(path: "removed-video-jobs.json")
        if FileManager.default.fileExists(atPath: exclusions.path) {
            do {
                excludedVideoTaskIDs = Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: exclusions)))
            } catch {
                taskHistoryIssue = String(localized: "无法读取任务历史：\(error.localizedDescription)")
            }
        }
        tasks = result.tasks.filter { task in
            task.deletedAt != nil || task.kind != .video || task.engineTaskID.map { !excludedVideoTaskIDs.contains($0) } ?? true
        }
        purgeExpiredTrash()
        var tracked = tasks
        for index in tracked.indices where tracked[index].completedAt != nil || [.completed, .seeding].contains(tracked[index].status) {
            FileTracker.resolve(&tracked[index])
        }
        if tracked != tasks { tasks = tracked }
        selectedTaskID = tasks.first { $0.deletedAt == nil }?.id
    }

    /// 在删列表和等待引擎之前原子保存用户意图；即使引擎离线也能跨启动排除。
    func excludeVideoFromHistory(_ task: DownloadTask) {
        guard let id = task.engineTaskID else { return }
        excludedVideoTaskIDs.insert(id)
        guard let historyStore else { return }
        let directory = historyStore.fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(excludedVideoTaskIDs.sorted()).write(
                to: directory.appending(path: "removed-video-jobs.json"), options: .atomic
            )
        } catch {
            taskHistoryIssue = String(localized: "无法保存任务历史：\(error.localizedDescription)")
        }
    }

    func flushTaskHistory() {
        do {
            try historyStore?.flush(tasks: tasks)
        } catch {
            taskHistoryIssue = String(localized: "无法保存任务历史：\(error.localizedDescription)")
        }
    }

    /// 正式运行交给协调器；没有协调器时保留预览和测试的示例行为。
    func addTasks(
        from links: [ParsedLink], autoExtract: Bool, directory: URL? = nil,
        filePriorities: [ParsedLink: [Int]] = [:]
    ) {
        if let coordinator {
            Task { await coordinator.add(
                links: links, autoExtract: autoExtract, directory: directory, filePriorities: filePriorities
            ) }
            return
        }
        let newTasks = links.map { DownloadTask(link: $0, autoExtract: autoExtract) }
        tasks.insert(contentsOf: newTasks, at: 0)
        selectedTaskID = newTasks.first?.id ?? selectedTaskID
    }

    private func updateSleepPrevention() {
        let active = tasks.contains { task in
            guard task.deletedAt == nil else { return false }
            return switch task.status {
            case .downloading, .queued, .extracting, .postProcessing: true
            case .seeding: !allowsSleepWhenDone
            case .waitingForSources: task.kind != .ed2k || !allowsSleepWhenDone
            default: false
            }
        }
        sleepPreventer.update(isActive: preventsSleepWhileDownloading && active)
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

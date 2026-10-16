import AppKit
import MuleeCore
import UserNotifications

@MainActor
protocol DownloadNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func configure(delegate: any UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>)
    func remove(identifiers: [String])
}

@MainActor
final class SystemDownloadNotificationCenter: DownloadNotificationCenter {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func configure(delegate: any UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>) {
        center.delegate = delegate
        center.setNotificationCategories(categories)
    }

    func remove(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// 首次真正发送时才请求权限；完成事件以十秒窗口合并。
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let openAction = "download.open"
    static let revealAction = "download.reveal"
    static let extractAction = "download.extract"
    static let cancelAction = "download.cancel-action"
    static let countdownIdentifier = "when-all-done.countdown"

    private let model: AppModel
    private let settings: SettingsModel
    private let center: any DownloadNotificationCenter
    private let now: () -> Date
    private var previous: [DownloadTask.ID: TaskStatus]
    private var completed: Set<DownloadTask.ID>
    private var pending: [DownloadTask] = []
    private var pendingSince: Date?
    private var delivery: Task<Void, Never>?
    private var generation = 0
    private var countdownGeneration = 0

    init(
        model: AppModel, settings: SettingsModel,
        center: any DownloadNotificationCenter = SystemDownloadNotificationCenter(),
        now: @escaping () -> Date = Date.init
    ) {
        self.model = model
        self.settings = settings
        self.center = center
        self.now = now
        previous = Dictionary(uniqueKeysWithValues: model.activeTasks.map { ($0.id, $0.status) })
        completed = Set(model.activeTasks.filter { [.completed, .seeding, .extracting].contains($0.status) }.map(\.id))
        super.init()
        model.notificationService = self
        let open = UNNotificationAction(identifier: Self.openAction, title: String(localized: "打开"), options: .foreground)
        let reveal = UNNotificationAction(identifier: Self.revealAction, title: String(localized: "在访达中显示"), options: .foreground)
        let extract = UNNotificationAction(identifier: Self.extractAction, title: String(localized: "解压"), options: .foreground)
        let cancel = UNNotificationAction(identifier: Self.cancelAction, title: String(localized: "取消"), options: .foreground)
        center.configure(delegate: self, categories: [
            UNNotificationCategory(identifier: "download", actions: [open, reveal], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "archive", actions: [open, reveal, extract], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: "countdown", actions: [cancel], intentIdentifiers: [], options: [])
        ])
    }

    isolated deinit { delivery?.cancel() }

    func tasksDidChange() {
        flushCompletionsIfDue()
        for task in model.activeTasks {
            if task.status == .failed {
                completed.remove(task.id)
                pending.removeAll { $0.id == task.id }
                if pending.isEmpty { pendingSince = nil }
            }
            if [.completed, .seeding, .extracting].contains(task.status), completed.insert(task.id).inserted,
               settings.notifyOnComplete {
                if pendingSince == nil { pendingSince = now() }
                pending.append(task)
            }
            if task.status == .failed, previous[task.id] != .failed, settings.notifyOnFailure {
                sendSystem(title: String(localized: "下载未完成"), body: task.errorMessage ?? task.name)
            }
        }
        previous = Dictionary(uniqueKeysWithValues: model.activeTasks.map { ($0.id, $0.status) })
    }

    func flushCompletionsIfDue() {
        guard let since = pendingSince, now().timeIntervalSince(since) >= 10 else { return }
        let tasks = pending.compactMap { pendingTask in
            model.tasks.first { $0.id == pendingTask.id && $0.deletedAt == nil && $0.status != .failed }
        }
        pending.removeAll()
        pendingSince = nil
        guard settings.notifyOnComplete, !tasks.isEmpty else { return }
        let content = UNMutableNotificationContent()
        content.title = tasks.count == 1 ? String(localized: "下载已完成") : String(localized: "\(tasks.count) 个下载已完成")
        content.body = tasks.map(\.name).joined(separator: "、")
        content.userInfo = ["taskIDs": tasks.map { $0.id.uuidString }]
        let hasManualArchive = tasks.contains {
            ArchiveVolumeDetector.detect(filename: $0.name, directoryFilenames: []).isArchive
                && (!settings.autoExtract || !$0.postDownload.autoExtract)
        }
        content.categoryIdentifier = hasManualArchive ? "archive" : "download"
        enqueue(content)
    }

    func sendSystem(title: String, body: String, countdown: Bool = false) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if countdown { content.categoryIdentifier = "countdown" }
        enqueue(content, identifier: countdown ? Self.countdownIdentifier : UUID().uuidString)
    }

    func cancelCountdown() {
        countdownGeneration += 1
        center.remove(identifiers: [Self.countdownIdentifier])
    }

    func refreshAuthorization() async {
        model.notificationPermissionDenied = await center.authorizationStatus() == .denied
    }

    func stop() {
        generation += 1
        delivery?.cancel()
        delivery = nil
        pending.removeAll()
        pendingSince = nil
    }

    private func enqueue(_ content: UNMutableNotificationContent, identifier: String = UUID().uuidString) {
        if settings.notificationSound { content.sound = .default }
        let token = generation
        let countdownToken = countdownGeneration
        let isCountdown = identifier == Self.countdownIdentifier
        let previousDelivery = delivery
        delivery = Task { [weak self] in
            await previousDelivery?.value
            guard let self, !Task.isCancelled, generation == token,
                  !isCountdown || countdownGeneration == countdownToken else { return }
            var status = await center.authorizationStatus()
            if status == .notDetermined {
                do {
                    let allowed = try await center.requestAuthorization()
                    status = allowed ? .authorized : .denied
                } catch {
                    status = await center.authorizationStatus()
                }
            }
            model.notificationPermissionDenied = status == .denied
            guard !Task.isCancelled, generation == token,
                  !isCountdown || countdownGeneration == countdownToken,
                  [.authorized, .provisional].contains(status) else { return }
            do {
                try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
                if isCountdown, countdownGeneration != countdownToken {
                    center.remove(identifiers: [identifier])
                }
            } catch {
                await refreshAuthorization()
            }
        }
    }

    /// 可等待注入的通知中心完成提交，测试无需等待系统回调。
    func waitForDelivery() async { await delivery?.value }

    func handleAction(_ action: String, taskIDs: [String]) {
        if action == Self.cancelAction {
            model.whenAllDoneController?.cancel()
            return
        }
        model.whenAllDoneController?.userDidInteract()
        let ids = Set(taskIDs.compactMap(UUID.init(uuidString:)))
        let tasks = model.activeTasks.filter { ids.contains($0.id) }
        for task in tasks {
            switch action {
            case Self.openAction:
                NSWorkspace.shared.open(TaskActions.localURL(for: task))
            case Self.revealAction:
                TaskActions.reveal(task)
            case Self.extractAction:
                guard !settings.autoExtract || !task.postDownload.autoExtract else { continue }
                model.extractionCoordinator?.requestExtraction(task.id)
            default:
                model.selectedTaskID = task.id
                model.mainWindowRequest += 1
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        let ids = response.notification.request.content.userInfo["taskIDs"] as? [String] ?? []
        await handleAction(action, taskIDs: ids)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

#if DEBUG
@MainActor
final class DownloadNotificationCenterSpy: DownloadNotificationCenter {
    var status: UNAuthorizationStatus = .notDetermined
    var grantsAuthorization = true
    private(set) var authorizationRequests = 0
    private(set) var requests: [UNNotificationRequest] = []
    private(set) var categories: Set<UNNotificationCategory> = []
    private(set) var removedIdentifiers: [String] = []

    func authorizationStatus() async -> UNAuthorizationStatus { status }

    func requestAuthorization() async throws -> Bool {
        authorizationRequests += 1
        status = grantsAuthorization ? .authorized : .denied
        return grantsAuthorization
    }

    func add(_ request: UNNotificationRequest) async throws { requests.append(request) }

    func configure(delegate: any UNUserNotificationCenterDelegate, categories: Set<UNNotificationCategory>) {
        self.categories = categories
    }

    func remove(identifiers: [String]) { removedIdentifiers += identifiers }
}
#endif

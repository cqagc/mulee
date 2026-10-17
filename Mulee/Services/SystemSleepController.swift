import AppKit
import MuleeCore
import Network

@MainActor
final class SystemSleepController {
    private let model: AppModel
    private let settings: SettingsModel
    private let waitForNetwork: @MainActor () async -> Void
    private var observers: [NSObjectProtocol] = []
    private var transition: Task<Void, Never>?
    private(set) var isSleeping = false
    private var generation = 0

    init(
        model: AppModel, settings: SettingsModel,
        waitForNetwork: @escaping @MainActor () async -> Void = SystemSleepController.waitForAvailableNetwork
    ) {
        self.model = model
        self.settings = settings
        self.waitForNetwork = waitForNetwork
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleTransition(sleeping: true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleTransition(sleeping: false) }
        })
        // 睡眠期间退出留下的暂停，同样等网络就绪后恢复。
        transition = Task { [weak self] in await self?.didWake() }
    }

    private func scheduleTransition(sleeping: Bool) {
        let previous = transition
        previous?.cancel()
        transition = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            if sleeping { await willSleep() }
            else { await didWake() }
        }
    }

    func stop() {
        generation += 1
        transition?.cancel()
        transition = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    isolated deinit {
        transition?.cancel()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    func willSleep() async {
        generation += 1
        isSleeping = true
        let token = generation
        guard settings.pauseOnSleep else { return }
        for task in model.activeTasks where [.http, .video].contains(task.kind) {
            guard !Task.isCancelled, generation == token, isSleeping else { return }
            await model.pauseAutomatically(task.id, reason: .systemSleep)
        }
    }

    func didWake() async {
        generation += 1
        let token = generation
        isSleeping = false
        guard model.activeTasks.contains(where: { model.automaticPauseReasons(for: $0).contains(.systemSleep) }) else { return }
        await waitForNetwork()
        guard !Task.isCancelled, generation == token, !isSleeping else { return }
        for task in model.activeTasks {
            guard generation == token, !isSleeping else { return }
            await model.resumeAutomatically(task.id, reason: .systemSleep)
        }
    }

    static func waitForAvailableNetwork() async {
        let monitor = NWPathMonitor()
        let (stream, continuation) = AsyncStream<Bool>.makeStream()
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied { continuation.yield(true); continuation.finish() }
        }
        monitor.start(queue: DispatchQueue(label: "mulee.wake.network"))
        defer { monitor.cancel(); continuation.finish() }
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in stream { return }
            }
            group.addTask { try? await Task.sleep(for: .seconds(30)) }
            await group.next()
            group.cancelAll()
        }
    }
}

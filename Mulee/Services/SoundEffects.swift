import AVFoundation
import Foundation
import MuleeCore

enum SoundEffect: String, CaseIterable, Sendable {
    case taskAdded = "task_added"
    case downloadComplete = "download_complete"
    case allComplete = "all_complete"
    case failed, pause, resume, delete
    case linkReceived = "link_received"
    case warning
}

enum SoundEffectEvent: Equatable {
    case taskAdded, failed, delete, linkReceived, warning, flush
    case completion(queueIsEmpty: Bool)
    case pause(manual: Bool)
    case resume(manual: Bool)
}

struct SoundEffectPreferences {
    var enabled = true
    var systemEnabled = true
    var notificationSound = false
    var isRunningUnitTests = false
    var isSynchronizing = false
}

/// 时间和偏好全部由调用方提供，规则测试不依赖时钟、音频设备或系统设置。
struct SoundEffectPolicy {
    private var lastPlayed: [SoundEffect: TimeInterval] = [:]
    private var pendingCompletion: SoundEffect?
    private(set) var completionDeadline: TimeInterval?

    mutating func cancelCompletion() {
        pendingCompletion = nil
        completionDeadline = nil
    }

    mutating func handle(
        _ event: SoundEffectEvent, at time: TimeInterval, preferences: SoundEffectPreferences
    ) -> SoundEffect? {
        guard preferences.enabled, preferences.systemEnabled,
              !preferences.isRunningUnitTests, !preferences.isSynchronizing else {
            cancelCompletion()
            return nil
        }
        if preferences.notificationSound { cancelCompletion() }
        let sound: SoundEffect
        switch event {
        case .taskAdded: sound = .taskAdded
        case .failed:
            guard !preferences.notificationSound else { return nil }
            sound = .failed
        case .delete: sound = .delete
        case .linkReceived: sound = .linkReceived
        case .warning: sound = .warning
        case .pause(let manual):
            guard manual else { return nil }
            sound = .pause
        case .resume(let manual):
            guard manual else { return nil }
            sound = .resume
        case .completion(let queueIsEmpty):
            guard !preferences.notificationSound else { return nil }
            pendingCompletion = queueIsEmpty ? .allComplete : .downloadComplete
            completionDeadline = time + 1
            return nil
        case .flush:
            guard let deadline = completionDeadline, time >= deadline, let pendingCompletion else { return nil }
            sound = pendingCompletion
            cancelCompletion()
        }
        guard lastPlayed[sound].map({ time - $0 >= 0.15 }) ?? true else { return nil }
        lastPlayed[sound] = time
        return sound
    }

    static func completionEvent(for tasks: [DownloadTask]) -> SoundEffectEvent {
        let queueIsEmpty = !tasks.contains {
            $0.deletedAt == nil && [.downloading, .queued, .waitingForSources, .postProcessing].contains($0.status)
        }
        return .completion(queueIsEmpty: queueIsEmpty)
    }

    static func needsSynchronization(previousSession: UUID?, currentSession: UUID?) -> Bool {
        previousSession != currentSession
    }

    static func transition(
        from previous: DownloadTask?, to task: DownloadTask, alreadyCompleted: Bool, synchronizing: Bool
    ) -> SoundEffectEvent? {
        guard !synchronizing, task.deletedAt == nil, let previous, previous.deletedAt == nil,
              previous.status != task.status else { return nil }
        if task.status == .failed { return .failed }
        if [.completed, .seeding, .extracting].contains(task.status), !alreadyCompleted,
           ![.completed, .seeding, .extracting].contains(previous.status) {
            return .completion(queueIsEmpty: false)
        }
        return nil
    }
}

struct SoundEffectWarningTracker {
    private var protectedVolumes: Set<String> = []

    mutating func update(_ volumes: Set<String>) -> Bool {
        let hasNewProtection = !volumes.subtracting(protectedVolumes).isEmpty
        protectedVolumes = volumes
        return hasNewProtection
    }
}

/// 音频文件读取、解码和设备预热放在独立 actor，避免阻塞主线程。
private actor SoundEffectPlayback {
    private var players: [SoundEffect: AVAudioPlayer] = [:]

    func preload(_ resources: [SoundEffect: URL]) {
        for (effect, url) in resources {
            guard let player = try? AVAudioPlayer(contentsOf: url) else { continue }
            player.prepareToPlay()
            players[effect] = player
        }
    }

    func play(_ effect: SoundEffect) {
        guard let player = players[effect] else { return }
        player.currentTime = 0
        player.play()
    }
}

@MainActor
final class SoundEffects {
    private let settings: SettingsModel
    private weak var model: AppModel?
    private let playback = SoundEffectPlayback()
    private var policy = SoundEffectPolicy()
    private var completedIDs: Set<UUID>
    private var pendingIDs: Set<UUID> = []
    private var announcedFailureIDs: Set<UUID> = []
    private var synchronizedKinds: Set<TaskKind> = []
    private var completionDelivery: Task<Void, Never>?
    private var preload: Task<Void, Never>?

    init(model: AppModel, settings: SettingsModel) {
        self.model = model
        self.settings = settings
        completedIDs = Set(model.activeTasks.filter { [.completed, .seeding, .extracting].contains($0.status) }.map(\.id))
        model.soundEffects = self
        guard !AppEnvironment.isRunningUnitTests else { return }
        let resources = Dictionary(uniqueKeysWithValues: SoundEffect.allCases.compactMap { effect in
            Bundle.main.url(forResource: effect.rawValue, withExtension: "caf", subdirectory: "Sounds").map { (effect, $0) }
        })
        preload = Task { [playback] in await playback.preload(resources) }
    }

    isolated deinit {
        preload?.cancel()
        completionDelivery?.cancel()
    }

    static var systemUISoundsEnabled: Bool {
        systemSoundsEnabled(value: UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["com.apple.sound.uiaudio.enabled"])
    }

    static func systemSoundsEnabled(value: Any?) -> Bool {
        (value as? NSNumber)?.boolValue ?? true
    }

    var isPlaybackEnabled: Bool {
        settings.uiSounds && Self.systemUISoundsEnabled && !AppEnvironment.isRunningUnitTests
    }

    private var preferences: SoundEffectPreferences {
        SoundEffectPreferences(
            enabled: settings.uiSounds, systemEnabled: Self.systemUISoundsEnabled,
            notificationSound: settings.notificationSound, isRunningUnitTests: AppEnvironment.isRunningUnitTests
        )
    }

    /// 手动操作不依赖下载轮询；所有播放入口仍统一经过偏好和去抖规则。
    func play(_ event: SoundEffectEvent) {
        if event == .warning, synchronizedKinds.isEmpty { return }
        if let sound = policy.handle(event, at: ProcessInfo.processInfo.systemUptime, preferences: preferences) {
            let preload = preload
            Task { [weak self, playback] in
                await preload?.value
                guard let self, isPlaybackEnabled,
                      !settings.notificationSound || ![.downloadComplete, .allComplete, .failed].contains(sound) else { return }
                await playback.play(sound)
            }
        }
    }

    func taskFailed(_ id: UUID) {
        guard announcedFailureIDs.insert(id).inserted else { return }
        play(.failed)
    }

    func beginSynchronization() {
        synchronizedKinds.removeAll()
        pendingIDs.removeAll()
        policy.cancelCompletion()
        completionDelivery?.cancel()
    }

    func didSynchronize(_ kinds: Set<TaskKind>) {
        synchronizedKinds.formUnion(kinds)
    }

    func resynchronize(_ kind: TaskKind) {
        synchronizedKinds.remove(kind)
        pendingIDs.removeAll()
        policy.cancelCompletion()
        completionDelivery?.cancel()
    }

    func tasksDidChange(previous: [DownloadTask], current: [DownloadTask]) {
        let previousByID = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var hasCompletion = false
        for task in current where task.deletedAt == nil {
            let event = SoundEffectPolicy.transition(
                from: previousByID[task.id], to: task, alreadyCompleted: completedIDs.contains(task.id),
                synchronizing: !synchronizedKinds.contains(task.kind)
            )
            if task.status != .failed { announcedFailureIDs.remove(task.id) }
            if task.status == .failed {
                completedIDs.remove(task.id)
                pendingIDs.remove(task.id)
            } else if [.completed, .seeding, .extracting].contains(task.status) {
                completedIDs.insert(task.id)
            }
            if case .completion = event {
                pendingIDs.insert(task.id)
                hasCompletion = true
            } else if event == .failed {
                taskFailed(task.id)
            }
        }
        let activeIDs = Set(current.filter { $0.deletedAt == nil }.map(\.id))
        pendingIDs.formIntersection(activeIDs)
        if pendingIDs.isEmpty { policy.cancelCompletion() }
        guard hasCompletion else { return }
        play(SoundEffectPolicy.completionEvent(for: current))
        completionDelivery?.cancel()
        completionDelivery = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
            guard let self else { return }
            play(.flush)
            pendingIDs.removeAll()
        }
    }
}

import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct SoundEffectsTests {
    @Test func userEventsMapToTheirSounds() {
        let cases: [(SoundEffectEvent, SoundEffect)] = [
            (.taskAdded, .taskAdded), (.failed, .failed), (.pause(manual: true), .pause),
            (.resume(manual: true), .resume), (.delete, .delete),
            (.linkReceived, .linkReceived), (.warning, .warning)
        ]
        for (event, expected) in cases {
            var policy = SoundEffectPolicy()
            #expect(policy.handle(event, at: 0, preferences: .init()) == expected)
        }
        var policy = SoundEffectPolicy()
        #expect(policy.handle(.pause(manual: false), at: 0, preferences: .init()) == nil)
        #expect(policy.handle(.resume(manual: false), at: 0, preferences: .init()) == nil)
    }

    @Test func completionBurstUsesLastEventAndTrailingOneSecondWindow() {
        var policy = SoundEffectPolicy()
        #expect(policy.handle(.completion(queueIsEmpty: false), at: 0, preferences: .init()) == nil)
        #expect(policy.handle(.completion(queueIsEmpty: true), at: 0.8, preferences: .init()) == nil)
        #expect(policy.handle(.flush, at: 1, preferences: .init()) == nil)
        #expect(policy.handle(.flush, at: 1.81, preferences: .init()) == .allComplete)
        #expect(policy.handle(.flush, at: 3, preferences: .init()) == nil)
        #expect(policy.handle(.completion(queueIsEmpty: false), at: 4, preferences: .init()) == nil)
        #expect(policy.handle(.flush, at: 5, preferences: .init()) == .downloadComplete)
    }

    @Test func debounceIsPerSoundAndAllowsBoundary() {
        var policy = SoundEffectPolicy()
        #expect(policy.handle(.pause(manual: true), at: 0, preferences: .init()) == .pause)
        #expect(policy.handle(.pause(manual: true), at: 0.149, preferences: .init()) == nil)
        #expect(policy.handle(.resume(manual: true), at: 0.149, preferences: .init()) == .resume)
        #expect(policy.handle(.pause(manual: true), at: 0.15, preferences: .init()) == .pause)
    }

    @Test func preferenceAndLifecycleGatesSuppressEveryEvent() {
        let events: [SoundEffectEvent] = [.taskAdded, .failed, .pause(manual: true), .resume(manual: true),
                                         .delete, .linkReceived, .warning, .completion(queueIsEmpty: true), .flush]
        let preferences: [SoundEffectPreferences] = [
            .init(enabled: false), .init(systemEnabled: false), .init(isRunningUnitTests: true),
            .init(isSynchronizing: true)
        ]
        for preference in preferences {
            var policy = SoundEffectPolicy()
            for event in events { #expect(policy.handle(event, at: 0, preferences: preference) == nil) }
            #expect(policy.handle(.flush, at: 2, preferences: .init()) == nil)
        }
    }

    @Test func notificationSoundSuppressesOnlyCompletionAndFailure() {
        var policy = SoundEffectPolicy()
        let preferences = SoundEffectPreferences(notificationSound: true)
        #expect(policy.handle(.failed, at: 0, preferences: preferences) == nil)
        #expect(policy.handle(.completion(queueIsEmpty: true), at: 0, preferences: preferences) == nil)
        #expect(policy.handle(.flush, at: 2, preferences: preferences) == nil)
        #expect(policy.handle(.warning, at: 2, preferences: preferences) == .warning)
        #expect(policy.handle(.taskAdded, at: 2, preferences: preferences) == .taskAdded)
        #expect(policy.handle(.completion(queueIsEmpty: false), at: 3, preferences: .init()) == nil)
        #expect(policy.handle(.flush, at: 4, preferences: preferences) == nil)
        #expect(policy.handle(.flush, at: 5, preferences: .init()) == nil)
    }

    @Test func taskTransitionsIgnoreRestoresSeedingRepeatsAndDeletion() {
        var before = MockData.tasks[0]
        before.status = .downloading
        var after = before
        after.status = .seeding
        #expect(SoundEffectPolicy.transition(from: before, to: after, alreadyCompleted: false, synchronizing: false) == .completion(queueIsEmpty: false))
        #expect(SoundEffectPolicy.transition(from: before, to: after, alreadyCompleted: false, synchronizing: true) == nil)
        #expect(SoundEffectPolicy.transition(from: nil, to: after, alreadyCompleted: false, synchronizing: false) == nil)
        before = after
        after.status = .completed
        #expect(SoundEffectPolicy.transition(from: before, to: after, alreadyCompleted: true, synchronizing: false) == nil)
        after.status = .failed
        #expect(SoundEffectPolicy.transition(from: before, to: after, alreadyCompleted: true, synchronizing: false) == .failed)
        after.deletedAt = .now
        #expect(SoundEffectPolicy.transition(from: before, to: after, alreadyCompleted: false, synchronizing: false) == nil)
        after.deletedAt = nil
        after.status = .paused
        after.pauseReason = .diskSpace
        #expect(SoundEffectPolicy.transition(from: before, to: after, alreadyCompleted: false, synchronizing: false) == nil)
    }

    @Test func completionChoosesQueueStateIncludingOtherEnginesAndTrash() {
        var task = MockData.tasks[0]
        for status: TaskStatus in [.downloading, .queued, .waitingForSources, .postProcessing] {
            task.status = status
            #expect(SoundEffectPolicy.completionEvent(for: [task]) == .completion(queueIsEmpty: false))
        }
        for status: TaskStatus in [.paused, .failed, .seeding, .completed, .extracting, .engineUnavailable] {
            task.status = status
            #expect(SoundEffectPolicy.completionEvent(for: [task]) == .completion(queueIsEmpty: true))
        }
        task.status = .downloading
        task.deletedAt = .now
        #expect(SoundEffectPolicy.completionEvent(for: [task]) == .completion(queueIsEmpty: true))
        #expect(SoundEffectPolicy.completionEvent(for: []) == .completion(queueIsEmpty: true))
    }

    @Test func warningIsOncePerProtectionEpisodeRegardlessOfTaskCount() {
        var tracker = SoundEffectWarningTracker()
        let firstPause = tracker.update(["volume-a"])
        #expect(firstPause)
        #expect(tracker.update(["volume-a"]) == false)
        let secondVolumePause = tracker.update(["volume-a", "volume-b"])
        #expect(secondVolumePause)
        #expect(tracker.update(["volume-a", "volume-b"]) == false)
        #expect(tracker.update(["volume-b"]) == false)
        #expect(tracker.update([]) == false)
        let pausedAgain = tracker.update(["volume-a"])
        #expect(pausedAgain)
    }

    @Test func changedEngineSessionRequiresSilentBaseline() {
        let first = UUID()
        let second = UUID()
        #expect(SoundEffectPolicy.needsSynchronization(previousSession: nil, currentSession: first))
        #expect(SoundEffectPolicy.needsSynchronization(previousSession: first, currentSession: first) == false)
        #expect(SoundEffectPolicy.needsSynchronization(previousSession: first, currentSession: second))
        #expect(SoundEffectPolicy.needsSynchronization(previousSession: first, currentSession: nil))
        #expect(SoundEffectPolicy.needsSynchronization(previousSession: nil, currentSession: nil) == false)
    }

    @Test func disabledAtDeliveryDiscardsPendingCompletionAndCancellationIsSilent() {
        for preferences in [SoundEffectPreferences(enabled: false), .init(systemEnabled: false),
                            .init(isRunningUnitTests: true), .init(isSynchronizing: true)] {
            var policy = SoundEffectPolicy()
            #expect(policy.handle(.completion(queueIsEmpty: true), at: 0, preferences: .init()) == nil)
            #expect(policy.handle(.flush, at: 2, preferences: preferences) == nil)
            #expect(policy.handle(.flush, at: 3, preferences: .init()) == nil)
        }
        var policy = SoundEffectPolicy()
        #expect(policy.handle(.completion(queueIsEmpty: true), at: 0, preferences: .init()) == nil)
        policy.cancelCompletion()
        #expect(policy.handle(.flush, at: 2, preferences: .init()) == nil)
    }

    @Test func failureTransitionOnlyPlaysOnceAndAutomaticPausesAreSilent() {
        var previous = MockData.tasks[0]
        previous.status = .downloading
        var current = previous
        current.status = .failed
        #expect(SoundEffectPolicy.transition(from: previous, to: current, alreadyCompleted: false, synchronizing: false) == .failed)
        #expect(SoundEffectPolicy.transition(from: current, to: current, alreadyCompleted: false, synchronizing: false) == nil)
        for reason: DownloadTask.PauseReason in [.diskSpace, .volumeUnavailable, .schedule] {
            current.status = .paused
            current.pauseReason = reason
            #expect(SoundEffectPolicy.transition(from: previous, to: current, alreadyCompleted: false, synchronizing: false) == nil)
            #expect(SoundEffectPolicy.transition(from: current, to: previous, alreadyCompleted: false, synchronizing: false) == nil)
        }
    }

    @Test func settingsDefaultOnPersistAndReadSystemDomain() throws {
        let storage = try TemporaryDefaults(prefix: "sound-settings.")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        #expect(settings.uiSounds)
        #expect(!settings.notificationSound)
        settings.uiSounds = false
        #expect(storage.defaults.object(forKey: "general.uiSounds") as? Bool == false)
        #expect(!SettingsModel(defaults: storage.defaults).uiSounds)
        #expect(SoundEffects.systemSoundsEnabled(value: nil))
        #expect(!SoundEffects.systemSoundsEnabled(value: 0))
        #expect(!SoundEffects.systemSoundsEnabled(value: false))
        #expect(SoundEffects.systemSoundsEnabled(value: 1))
        #expect(SoundEffects.systemSoundsEnabled(value: true))
    }

    @Test func resourcesAreBundledAndHostCannotPlay() throws {
        for effect in SoundEffect.allCases {
            let url = try #require(Bundle.main.url(forResource: effect.rawValue, withExtension: "caf", subdirectory: "Sounds"))
            #expect(try Data(contentsOf: url).prefix(4) == Data("caff".utf8))
        }
        let storage = try TemporaryDefaults(prefix: "sound-host.")
        defer { storage.clean() }
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let service = SoundEffects(model: model, settings: SettingsModel(defaults: storage.defaults))
        service.play(.warning)
        #expect(AppEnvironment.isRunningUnitTests)
        #expect(!service.isPlaybackEnabled)
    }
}

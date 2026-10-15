import Sparkle
import SwiftUI
import Testing
@testable import Mulee

@MainActor
@Suite struct AppUpdateTests {
    @Test func preferencesBindDirectlyToSparkle() {
        let updater = AppUpdateUpdaterStub()
        let updates = AppUpdateController(updater: updater)
        let checks = Binding(get: { updates.automaticallyChecksForUpdates }, set: { updates.automaticallyChecksForUpdates = $0 })
        let downloads = Binding(get: { updates.automaticallyDownloadsUpdates }, set: { updates.automaticallyDownloadsUpdates = $0 })

        checks.wrappedValue = false
        downloads.wrappedValue = true
        #expect(!updater.automaticallyChecksForUpdates)
        #expect(updater.automaticallyDownloadsUpdates)

        updater.automaticallyChecksForUpdates = true
        updater.automaticallyDownloadsUpdates = false
        #expect(checks.wrappedValue)
        #expect(!downloads.wrappedValue)
    }

    @Test func automaticChecksAreOnlyAllowedInReleaseOutsideTests() {
        #expect(AppUpdateController.permitsAutomaticChecks(isDebug: false, isRunningUnitTests: false))
        #expect(!AppUpdateController.permitsAutomaticChecks(isDebug: true, isRunningUnitTests: false))
        #expect(!AppUpdateController.permitsAutomaticChecks(isDebug: false, isRunningUnitTests: true))
        #expect(!AppUpdateController.permitsAutomaticChecks(isDebug: true, isRunningUnitTests: true))
    }

    @Test func testHostNeverStartsUpdaterEvenForManualCheck() throws {
        #expect(AppEnvironment.isRunningUnitTests)
        let updater = AppUpdateUpdaterStub()
        let updates = AppUpdateController(updater: updater)
        updates.startAutomaticChecks()
        updates.checkForUpdates()
        #expect(!updates.isStarted)
        #expect(updater.startCount == 0)
        #expect(!updates.canCheckForUpdates)
        #expect(throws: (any Error).self) {
            try updates.updater(updater, mayPerform: .updatesInBackground)
        }
    }

    @Test func cancellingActiveDownloadsDoesNotStopEnginesOrInstall() async {
        let installation = AppUpdateInstallation()
        var preparations = 0
        installation.hasActiveTransfers = { true }
        installation.confirm = { false }
        installation.prepare = {
            preparations += 1
            return true
        }
        #expect(!installation.mayInstall())
        #expect(await !installation.prepareForInstallation())
        #expect(preparations == 0)
        #expect(!installation.isPrepared)
    }

    @Test func confirmsOnceAndWaitsForSavedProgressBeforeInstalling() async {
        let installation = AppUpdateInstallation()
        var events: [String] = []
        installation.hasActiveTransfers = { true }
        installation.confirm = {
            events.append("confirm")
            return true
        }
        installation.prepare = {
            #expect(!installation.isPrepared)
            events.append("stop and save")
            await Task.yield()
            return true
        }
        #expect(installation.mayInstall())
        #expect(await installation.prepareForInstallation())
        #expect(installation.isPrepared)
        #expect(installation.mayInstall())
        #expect(events == ["confirm", "stop and save"])
    }

    @Test func idleInstallDoesNotPromptAndSaveFailurePreventsInstallation() async {
        let installation = AppUpdateInstallation()
        installation.confirm = {
            Issue.record("Idle installation should not prompt")
            return false
        }
        installation.prepare = { false }
        #expect(await !installation.prepareForInstallation())
        #expect(!installation.isPrepared)
        installation.reset()
        installation.hasActiveTransfers = { true }
        installation.confirm = { false }
        #expect(!installation.mayInstall())
    }

    @Test func simultaneousQuitAndRelaunchShareOneShutdown() async {
        let installation = AppUpdateInstallation()
        var preparations = 0
        installation.prepare = {
            preparations += 1
            await Task.yield()
            return true
        }
        let relaunch = Task { await installation.prepareForInstallation() }
        let quit = Task { await installation.prepareForInstallation() }
        #expect(await relaunch.value)
        #expect(await quit.value)
        #expect(preparations == 1)
    }
}

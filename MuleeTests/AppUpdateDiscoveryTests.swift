import Foundation
import Sparkle
import Testing

@MainActor
@Suite struct AppUpdateDiscoveryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MULEE_APP_UPDATE_TEST_BUNDLE"] != nil))
    func localFeedFindsAndParsesNewVersionWithoutInstalling() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MULEE_APP_UPDATE_TEST_BUNDLE"])
        let bundle = try #require(Bundle(path: path))
        let probe = AppUpdateDiscoveryProbe()
        let updater = SPUUpdater(
            hostBundle: bundle, applicationBundle: .main,
            userDriver: SPUStandardUserDriver(hostBundle: bundle, delegate: nil), delegate: probe
        )
        try updater.start()
        updater.checkForUpdateInformation()
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !probe.finished && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(probe.finished)
        #expect(probe.error == nil)
        #expect(probe.parsedItems == 1)
        #expect(probe.version == "999999")
    }
}

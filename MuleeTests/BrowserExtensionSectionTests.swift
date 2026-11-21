import AppKit
import SwiftUI
import Testing
@testable import Mulee

@Suite @MainActor
struct BrowserExtensionSectionTests {
    @Test func readsAgainWhileMountedAndWhenMuleeBecomesActive() async throws {
        var enabled = false
        var values: [Bool] = []
        let section = BrowserExtensionSection(readSafariEnabled: {
            values.append(enabled)
            return enabled
        }, refreshInterval: .milliseconds(80))
        let host = NSHostingController(rootView: Form { section }.formStyle(.grouped))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer {
            window.close()
            window.contentViewController = nil
        }
        try await waitUntil { values.last == false }
        enabled = true
        try await waitUntil { values.last == true }
        enabled = false
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await waitUntil { values.last == false }
    }

    @Test func activationRefreshesBeforeNextScheduledRead() async throws {
        var reads = 0
        let host = NSHostingController(rootView: BrowserExtensionSection(readSafariEnabled: {
            reads += 1
            return true
        }, refreshInterval: .seconds(120)))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer {
            window.close()
            window.contentViewController = nil
        }
        try await waitUntil { reads > 0 }
        let before = reads
        NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: NSApp)
        try await waitUntil { reads > before }
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(15))
        }
        try #require(predicate())
    }
}

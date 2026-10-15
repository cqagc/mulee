import Foundation
import Testing
@testable import Mulee

@Suite @MainActor struct OnboardingTests {
    @Test func asksOnlyOnceAcrossLaunches() throws {
        let name = "MuleeOnboardingTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(OnboardingPolicy.claimPresentation(defaults: defaults, usesSampleData: false, isRunningUnitTests: false))
        let nextLaunch = try #require(UserDefaults(suiteName: name))
        #expect(!OnboardingPolicy.claimPresentation(defaults: nextLaunch, usesSampleData: false, isRunningUnitTests: false))
    }

    @Test func samplesAndTestHostsDoNotConsumeFirstLaunch() throws {
        let name = "MuleeOnboardingTests-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!OnboardingPolicy.claimPresentation(defaults: defaults, usesSampleData: true, isRunningUnitTests: false))
        #expect(!OnboardingPolicy.claimPresentation(defaults: defaults, usesSampleData: false, isRunningUnitTests: true))
        #expect(!defaults.bool(forKey: OnboardingPolicy.askedKey))
        #expect(OnboardingPolicy.claimPresentation(defaults: defaults, usesSampleData: false, isRunningUnitTests: false))
    }
}

import Testing
@testable import Mulee

@Suite struct SleepPreventerTests {
    private final class FakeProvider: PowerAssertionProviding {
        var created = 0
        var released: [UInt32] = []
        var shouldFail = false

        func createAssertion(reason: String) -> UInt32? {
            guard !shouldFail else { return nil }
            created += 1
            return UInt32(created)
        }

        func releaseAssertion(_ id: UInt32) {
            released.append(id)
        }
    }

    @Test func activeCreatesOneAssertion() {
        let provider = FakeProvider()
        let preventer = SleepPreventer(provider: provider)
        preventer.update(isActive: true)
        preventer.update(isActive: true)
        #expect(preventer.isPreventingSleep)
        #expect(provider.created == 1)
    }

    @Test func inactiveReleasesAssertionOnce() {
        let provider = FakeProvider()
        let preventer = SleepPreventer(provider: provider)
        preventer.update(isActive: true)
        preventer.update(isActive: false)
        preventer.update(isActive: false)
        #expect(!preventer.isPreventingSleep)
        #expect(provider.released == [1])
    }

    @Test func inactiveWithoutAssertionDoesNothing() {
        let provider = FakeProvider()
        let preventer = SleepPreventer(provider: provider)
        preventer.update(isActive: false)
        #expect(provider.released.isEmpty)
    }

    @Test func failedCreationLeavesNotPreventing() {
        let provider = FakeProvider()
        provider.shouldFail = true
        let preventer = SleepPreventer(provider: provider)
        preventer.update(isActive: true)
        #expect(!preventer.isPreventingSleep)
    }

    @Test func deinitReleasesAssertion() {
        let provider = FakeProvider()
        var preventer: SleepPreventer? = SleepPreventer(provider: provider)
        preventer?.update(isActive: true)
        preventer = nil
        #expect(provider.released == [1])
    }
    @Test func lowPowerModeReleasesAndDoesNotAcquireAssertion() {
        let provider = FakeProvider()
        var lowPower = false
        let preventer = SleepPreventer(provider: provider, lowPowerMode: { lowPower })
        preventer.update(isActive: true)
        #expect(preventer.isPreventingSleep)
        lowPower = true
        preventer.update(isActive: true)
        #expect(!preventer.isPreventingSleep)
        #expect(provider.released == [1])
        preventer.update(isActive: true)
        #expect(provider.created == 1)
        lowPower = false
        preventer.update(isActive: true)
        #expect(provider.created == 2)
    }

}

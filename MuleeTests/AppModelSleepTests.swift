import Testing
@testable import Mulee

/// AppModel 根据任务状态自动阻止或放行系统睡眠。
@Suite struct AppModelSleepTests {
    private final class CountingProvider: PowerAssertionProviding {
        private(set) var created = 0
        private(set) var released = 0

        func createAssertion(reason: String) -> UInt32? {
            created += 1
            return UInt32(created)
        }

        func releaseAssertion(_ id: UInt32) {
            released += 1
        }
    }

    @Test func pauseAllReleasesAndResumeReacquires() {
        let provider = CountingProvider()
        let model = AppModel(sleepPreventer: SleepPreventer(provider: provider))
        #expect(model.isPreventingSleep)

        model.pauseAll()
        // 示例数据里还有做种、解压、合并中的任务，它们仍在传输，所以不应放行睡眠。
        #expect(model.isPreventingSleep == model.hasActiveTransfers)

        for task in model.tasks {
            model.remove(task.id)
        }
        #expect(!model.isPreventingSleep)
        #expect(provider.released == 1)

        model.addTasks(from: LinkParserFixtures.oneHTTPLink, autoExtract: false)
        #expect(model.isPreventingSleep)
        #expect(provider.created == 2)
    }

    @Test func disablingPreferenceImmediatelyReleasesAndEnablingReacquires() {
        let provider = CountingProvider()
        let model = AppModel(sleepPreventer: SleepPreventer(provider: provider))
        #expect(model.hasActiveTransfers)
        #expect(provider.created == 1)

        model.preventsSleepWhileDownloading = false

        #expect(!model.isPreventingSleep)
        #expect(provider.released == 1)

        model.addTasks(from: LinkParserFixtures.oneHTTPLink, autoExtract: false)
        #expect(!model.isPreventingSleep)
        #expect(provider.created == 1)

        model.preventsSleepWhileDownloading = true

        #expect(model.isPreventingSleep)
        #expect(provider.created == 2)
        #expect(provider.released == 1)
    }

    @Test func disabledInitialPreferenceDoesNotAcquireAssertion() {
        let provider = CountingProvider()
        let model = AppModel(
            preventsSleepWhileDownloading: false,
            sleepPreventer: SleepPreventer(provider: provider)
        )

        #expect(model.hasActiveTransfers)
        #expect(!model.isPreventingSleep)
        #expect(provider.created == 0)
    }

    @Test func enablingWithoutActiveTransfersDoesNotAcquireAssertion() {
        let provider = CountingProvider()
        let model = AppModel(
            tasks: [],
            preventsSleepWhileDownloading: false,
            sleepPreventer: SleepPreventer(provider: provider)
        )

        model.preventsSleepWhileDownloading = true

        #expect(!model.isPreventingSleep)
        #expect(provider.created == 0)
    }
}

import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct PublicTrackerControllerTests {
    @Test("订阅缓存展示、手填地址优先和开关变化读取真实设置")
    func settingsConsumption() async throws {
        let defaults = try TemporaryDefaults(prefix: "mulee.tests.trackers.")
        defer { defaults.clean() }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.trackerSubscriptions = "https://example.com/list"
        let response = Response()
        let service = PublicTrackerSubscriptionService(fileURL: root.appending(path: "cache.json"), loader: { try await response.load($0) })
        let engine = TorrentEngine(stateDirectory: root.appending(path: "engine"))
        let controller = PublicTrackerController(service: service, engine: engine, settings: settings)
        await controller.start()?.value
        #expect(!controller.isUpdating)
        #expect(controller.updatedAt != nil)
        #expect(controller.trackerCount == 1)
        #expect(controller.issue == nil)
        settings.customTrackers = "invalid\nhttps://custom.example.com/announce\nhttps://tracker.example.com/announce"
        await controller.settingsChanged()?.value
        #expect(controller.trackerCount == 2)
        #expect(await response.calls == 1)
        settings.publicTrackersEnabled = false
        await controller.settingsChanged()?.value
        #expect(await response.calls == 1)
        settings.trackerSubscriptions = ""
        settings.customTrackers = ""
        await controller.settingsChanged()?.value
        #expect(controller.trackerCount == 0)
        controller.stop()
    }

    @Test("关闭订阅不会发请求；失败提示保留缓存，手动可重试")
    func disabledAndFailedRefresh() async throws {
        let defaults = try TemporaryDefaults(prefix: "mulee.tests.trackers.")
        defer { defaults.clean() }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = SettingsModel(defaults: defaults.defaults)
        settings.trackerSubscriptions = "https://example.com/list"
        settings.publicTrackersEnabled = false
        let response = Response()
        let service = PublicTrackerSubscriptionService(fileURL: root.appending(path: "cache.json"), loader: { try await response.load($0) })
        let controller = PublicTrackerController(service: service, engine: TorrentEngine(stateDirectory: root), settings: settings)
        await controller.start()?.value
        #expect(await response.calls == 0)
        settings.publicTrackersEnabled = true
        controller.settingsChanged()
        await controller.updateNow()?.value
        #expect(await response.calls == 1)
        let updated = try #require(controller.updatedAt)
        await response.setFailing()
        await controller.updateNow()?.value
        #expect(controller.issue != nil)
        #expect(controller.trackerCount == 1)
        #expect(controller.updatedAt == updated)
        #expect(await response.calls == 2)
        controller.stop()
    }

    private actor Response {
        private var failing = false
        private(set) var calls = 0

        func setFailing() { failing = true }
        func load(_ url: URL) throws -> Data {
            calls += 1
            guard !failing else { throw URLError(.timedOut) }
            return Data("https://tracker.example.com/announce".utf8)
        }
    }
}

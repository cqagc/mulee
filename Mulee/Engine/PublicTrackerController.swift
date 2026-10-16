import Foundation
import MuleeCore
import Observation

/// 设置页共享更新状态；只由正式启动路径创建服务，预览与测试不会访问用户缓存。
@Observable
final class PublicTrackerController {
    private let service: PublicTrackerSubscriptionService
    private let engine: TorrentEngine
    private let settings: SettingsModel
    private var updateTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var revision = UUID()
    private var cache = PublicTrackerCache()
    private var activeSubscriptions: [[URL]] = []
    var isUpdating = false
    var updatedAt: Date?
    var trackerCount = 0
    var issue: String?

    init(service: PublicTrackerSubscriptionService, engine: TorrentEngine, settings: SettingsModel) {
        self.service = service
        self.engine = engine
        self.settings = settings
    }

    @discardableResult
    func start() -> Task<Void, Never>? {
        settingsChanged()
        return updateTask
    }

    func stop() {
        updateTask?.cancel()
        applyTask?.cancel()
    }

    @discardableResult
    func settingsChanged() -> Task<Void, Never>? {
        revision = UUID()
        do {
            activeSubscriptions = try PublicTrackerList.subscriptions(settings.trackerSubscriptions)
            issue = nil
        } catch {
            issue = error.localizedDescription
        }
        apply()
        update(force: false)
        return applyTask
    }

    @discardableResult
    func updateNow() -> Task<Void, Never>? {
        update(force: true)
        return updateTask
    }

    private func update(force: Bool) {
        guard !isUpdating else { return }
        let subscriptions: [[URL]]
        do {
            subscriptions = try PublicTrackerList.subscriptions(settings.trackerSubscriptions)
        } catch {
            issue = error.localizedDescription
            return
        }
        isUpdating = true
        updateTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isUpdating = false }
            // Read and apply the cache before waiting for a slow network request.
            self.cache = await self.service.snapshot()
            guard !Task.isCancelled else { return }
            self.apply()
            guard self.settings.publicTrackersEnabled else {
                await self.applyTask?.value
                return
            }
            do {
                let failures = try await self.service.refresh(subscriptions: subscriptions, force: force)
                self.cache = await self.service.snapshot()
                guard !Task.isCancelled else { return }
                self.issue = failures > 0 ? "部分订阅更新失败，已保留上次结果" : nil
                self.apply()
                await self.applyTask?.value
            } catch {
                guard !Task.isCancelled else { return }
                self.issue = "无法更新或保存 tracker 列表，已保留上次结果"
            }
        }
    }

    private func apply() {
        let trackers = Array(PublicTrackerList.parse(
            settings.customTrackers + "\n" + cache.trackers(for: activeSubscriptions).joined(separator: "\n")
        ).prefix(50))
        updatedAt = cache.updatedAt
        trackerCount = trackers.count
        let urls = settings.publicTrackersEnabled ? trackers : []
        let custom = Set(PublicTrackerList.parse(settings.customTrackers))
        let subscriptions = settings.publicTrackersEnabled
            ? cache.trackers(for: activeSubscriptions).filter { !custom.contains($0) } : []
        let token = revision
        let previous = applyTask
        applyTask = Task { [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled, self.revision == token else { return }
            await self.engine.configurePublicTrackers(urls, subscriptionURLs: subscriptions)
        }
    }
}

import Foundation
import MuleeCore

/// 协调器每秒提供快照；额度每三秒计算一次，整批变化不足 10% 时保留原分配。
final class DownloadScheduling {
    private let pauses: QueuePauseStore
    private var samples: [TaskKind: [Int64]] = [:]
    private var uploads: [TaskKind: [Int64]] = [:]
    private var applied: [TaskKind: EngineOptions] = [:]
    private var previousOptions: EngineOptions?
    private var lastAdjustment: Date?
    private var busy = false

    init(defaults: UserDefaults?) {
        pauses = QueuePauseStore(defaults: defaults)
    }

    func reset() {
        samples.removeAll()
        uploads.removeAll()
        applied.removeAll()
        previousOptions = nil
        lastAdjustment = nil
    }

    func startupOptions(_ options: EngineOptions, kind: TaskKind, kinds: Set<TaskKind>) -> EngineOptions {
        if let existing = applied[kind] { return existing }
        var result = options
        if options.downloadLimit > 0 {
            result.downloadLimit = max(1, options.downloadLimit / Int64(max(1, kinds.count)))
        }
        if options.uploadLimit > 0, [.bittorrent, .ed2k].contains(kind) {
            result.uploadLimit = max(1, options.uploadLimit / Int64(max(1, kinds.intersection([.bittorrent, .ed2k]).count)))
        } else {
            result.uploadLimit = 0
        }
        result = quantized(result, kind: kind)
        applied[kind] = result
        return result
    }

    func queue(_ task: DownloadTask) {
        pauses.set("queue", for: task)
    }

    func userPause(_ task: DownloadTask) {
        pauses.set("user", for: task)
    }

    func userResume(_ task: DownloadTask) {
        pauses.set(nil, for: task)
    }

    func removed(_ task: DownloadTask) {
        pauses.set(nil, for: task)
    }

    func isQueuePaused(_ task: DownloadTask) -> Bool {
        pauses.reason(for: task) == "queue"
    }

    func refresh(
        model: AppModel, engines: [any DownloadEngine], options: EngineOptions,
        now: Date = .now, sample: Bool = true, isCurrent: () -> Bool
    ) async {
        guard !busy, isCurrent() else { return }
        busy = true
        defer { busy = false }
        let enginePaused = Set(model.activeTasks.filter { $0.status == .paused }.map(\.id))
        for task in model.activeTasks where task.pauseReason == nil {
            if pauses.reason(for: task) == "queue", task.status == .paused {
                if let index = model.tasks.firstIndex(where: { $0.id == task.id }) {
                    model.tasks[index].status = .queued
                }
            } else if pauses.reason(for: task) == "user", [.downloading, .queued].contains(task.status) {
                // 用户操作可能与轮询交错；用户暂停意图优先。
                if let id = task.engineTaskID, let engine = engines.first(where: { $0.kind == task.kind }) {
                    do { try await engine.pause(id) }
                    catch {
                        if isCurrent() { report(error, task: task, model: model) }
                        return
                    }
                    guard isCurrent(), let current = model.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                    model.tasks[current].status = .paused
                    model.tasks[current].downloadRate = 0
                    model.tasks[current].uploadRate = 0
                }
            }
        }
        let admitted = GlobalConcurrencyPolicy.admitted(tasks: model.activeTasks.filter { $0.pauseReason == nil }, limit: options.maxConcurrentDownloads)
        // 先暂停超额任务，再释放名额，避免一次轮询内短暂恢复过多任务。
        for task in model.activeTasks where task.pauseReason == nil && GlobalConcurrencyPolicy.occupiesSlot(task) && !admitted.contains(task.id) {
            guard isCurrent(), let id = task.engineTaskID,
                  let engine = engines.first(where: { $0.kind == task.kind }) else { continue }
            guard pauses.reason(for: task) != "user",
                  !isQueuePaused(task) || !enginePaused.contains(task.id) else { continue }
            pauses.set("queue", for: task)
            do {
                try await engine.pause(id)
                guard isCurrent() else { return }
                if let index = model.tasks.firstIndex(where: { $0.id == task.id }), isQueuePaused(task) {
                    model.tasks[index].status = .queued
                    model.tasks[index].downloadRate = 0
                    model.tasks[index].uploadRate = 0
                }
            } catch {
                guard isCurrent() else { return }
                if isQueuePaused(task) { pauses.set(nil, for: task) }
                report(error, task: task, model: model)
                // 暂停失败时不能再放行其他任务。
                return
            }
        }
        if sample {
            for kind in TaskKind.allCases {
                let tasks = model.activeTasks.filter { $0.kind == kind && !isQueuePaused($0) }
                samples[kind] = Array(((samples[kind] ?? []) + [tasks.reduce(0) { $0 + max(0, $1.downloadRate) }]).suffix(3))
                uploads[kind] = Array(((uploads[kind] ?? []) + [tasks.reduce(0) { $0 + max(0, $1.uploadRate) }]).suffix(3))
            }
        }
        let changed = options != previousOptions
        if changed || lastAdjustment == nil || now.timeIntervalSince(lastAdjustment ?? now) >= 3 {
            let desired = allocation(options: options, tasks: model.activeTasks, engines: engines, admitted: admitted, reset: changed)
            let significant = changed || desired.contains { kind, value in
                guard let old = applied[kind] else { return true }
                return significantChange(old.downloadLimit, value.downloadLimit)
                    || significantChange(old.uploadLimit, value.uploadLimit)
            }
            lastAdjustment = now
            if significant {
                // 降额先于加额；整批去抖，不能单独抑制降额后仍给另一引擎加额。
                let ordered = engines
                // 双方向可能相反：先把每个方向都降到新旧值的较小值，再整体加额。
                for engine in ordered {
                    guard isCurrent(), let next = desired[engine.kind] else { return }
                    if let old = applied[engine.kind] {
                        var reduced = next
                        reduced.downloadLimit = lowerLimit(old.downloadLimit, next.downloadLimit)
                        reduced.uploadLimit = lowerLimit(old.uploadLimit, next.uploadLimit)
                        if reduced != old {
                            guard await apply(reduced, engine: engine, model: model, isCurrent: isCurrent) else { return }
                        }
                    }
                }
                for engine in ordered {
                    guard isCurrent(), let next = desired[engine.kind] else { return }
                    if applied[engine.kind] != next {
                        guard await apply(next, engine: engine, model: model, isCurrent: isCurrent) else { return }
                    }
                }
            }
            // 尚在准备或启动失败的引擎也保留一个安全额度，迟到启动不能额外获得一份全局额度。
            for (kind, value) in desired where !engines.contains(where: { $0.kind == kind }) {
                applied[kind] = value
            }
            previousOptions = options
        }
        for task in model.activeTasks where task.pauseReason == nil && admitted.contains(task.id) && isQueuePaused(task) {
            guard isCurrent(), let id = task.engineTaskID,
                  let engine = engines.first(where: { $0.kind == task.kind }) else { continue }
            guard model.tasks.contains(where: { $0.id == task.id && $0.pauseReason == nil }) else { continue }
            do {
                try await engine.resume(id)
                guard isCurrent() else { return }
                if let current = model.tasks.first(where: { $0.id == task.id }), current.pauseReason != nil {
                    try await engine.pause(id)
                    continue
                }
                if isQueuePaused(task) { pauses.set(nil, for: task) }
            } catch {
                guard isCurrent() else { return }
                report(error, task: task, model: model)
            }
        }
    }

    private func allocation(
        options: EngineOptions, tasks: [DownloadTask], engines: [any DownloadEngine],
        admitted: Set<DownloadTask.ID>, reset: Bool
    ) -> [TaskKind: EngineOptions] {
        var downloadDemand: [TaskKind: BandwidthAllocator.Demand] = [:]
        var uploadDemand: [TaskKind: BandwidthAllocator.Demand] = [:]
        for engine in engines {
            let current = tasks.filter { $0.kind == engine.kind }
            let downloading = current.filter {
                admitted.contains($0.id) || ($0.status == .waitingForSources && $0.downloadRate > 0 && !isQueuePaused($0))
            }.count
            downloadDemand[engine.kind] = .init(rate: average(samples[engine.kind]), activeTasks: downloading)
            if [.bittorrent, .ed2k].contains(engine.kind) {
                let uploading = current.filter {
                    [.downloading, .seeding, .waitingForSources, .completed].contains($0.status)
                        || admitted.contains($0.id)
                }.count
                uploadDemand[engine.kind] = .init(rate: average(uploads[engine.kind]), activeTasks: uploading)
            }
        }
        var reserved: [TaskKind: Int64] = [:]
        if !reset, tasks.contains(where: { $0.kind == .video && $0.status == .downloading }),
           let rate = applied[.video]?.downloadLimit, rate > 0 {
            reserved[.video] = rate
        }
        // 空闲引擎停在最小非零限速，避免 0（不限速）让新任务绕过下一次调度。
        let kinds = Set(applied.keys).union(engines.map(\.kind))
        let parkedDownload = kinds.filter { (downloadDemand[$0]?.activeTasks ?? 0) == 0 }
            .reduce(Int64(0)) { $0 + parkingLimit($1) }
        let parkedUpload = kinds.filter { [.bittorrent, .ed2k].contains($0) && (uploadDemand[$0]?.activeTasks ?? 0) == 0 }
            .reduce(Int64(0)) { $0 + parkingLimit($1) }
        let download = BandwidthAllocator.allocate(
            limit: options.downloadLimit > 0 ? max(1, options.downloadLimit - parkedDownload) : 0,
            demand: downloadDemand, previous: applied.mapValues(\.downloadLimit), reserved: reserved
        )
        let upload = BandwidthAllocator.allocate(
            limit: options.uploadLimit > 0 ? max(1, options.uploadLimit - parkedUpload) : 0,
            demand: uploadDemand, previous: applied.mapValues(\.uploadLimit)
        )
        return Dictionary(uniqueKeysWithValues: kinds.map { kind in
            var next = options
            next.downloadLimit = options.downloadLimit == 0 ? 0 : download[kind] ?? parkingLimit(kind)
            next.uploadLimit = options.uploadLimit == 0 || ![.bittorrent, .ed2k].contains(kind)
                ? 0 : upload[kind] ?? parkingLimit(kind)
            return (kind, quantized(next, kind: kind))
        })
    }

    private func quantized(_ options: EngineOptions, kind: TaskKind) -> EngineOptions {
        guard kind == .ed2k else { return options }
        var next = options
        // EC 使用 KiB/s，提前向下对齐，避免多个引擎分别向上取整后超过总上限。
        if next.downloadLimit > 0 { next.downloadLimit = max(1024, next.downloadLimit / 1024 * 1024) }
        if next.uploadLimit > 0 { next.uploadLimit = max(1024, next.uploadLimit / 1024 * 1024) }
        return next
    }

    private func parkingLimit(_ kind: TaskKind) -> Int64 { kind == .ed2k ? 1024 : 1 }

    private func average(_ values: [Int64]?) -> Int64 {
        guard let values, !values.isEmpty else { return 0 }
        return values.reduce(0) { $0 + $1 / Int64(values.count) }
    }

    private func significantChange(_ old: Int64, _ new: Int64) -> Bool {
        if old == 0 || new == 0 { return old != new }
        return Double(abs(new - old)) / Double(old) >= 0.1
    }

    private func lowerLimit(_ old: Int64, _ new: Int64) -> Int64 {
        if old == 0 { return new }
        if new == 0 { return old }
        return min(old, new)
    }

    private func apply(
        _ options: EngineOptions, engine: any DownloadEngine, model: AppModel, isCurrent: () -> Bool
    ) async -> Bool {
        do {
            try await engine.apply(options: options)
            guard isCurrent() else { return false }
            applied[engine.kind] = options
            return true
        } catch {
            guard isCurrent() else { return false }
            model.engineStates[engine.kind] = .failed(EngineStatusPresentation.errorMessage(error))
            return false
        }
    }

    private func report(_ error: any Error, task: DownloadTask, model: AppModel) {
        guard let index = model.tasks.firstIndex(where: { $0.id == task.id }) else { return }
        model.tasks[index].errorMessage = EngineStatusPresentation.errorMessage(error)
    }
}

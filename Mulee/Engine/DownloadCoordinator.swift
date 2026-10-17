import Foundation
import MuleeCore

/// 把引擎的异步操作与主线程上的 UI 状态连接起来。
@MainActor
final class DownloadCoordinator {
    private let model: AppModel
    private var engines: [any DownloadEngine]
    private let videoBootstrap: VideoEngineBootstrap?
    private let videoEngineFactory: (@MainActor (VideoEngineConfiguration) async throws -> any DownloadEngine)?
    private var waitingVideoLinks: [DownloadTask.ID: (link: ParsedLink, directory: URL?, entry: YtDlpPlaylistEntry?, formatID: String?, videoOnly: Bool)] = [:]
    private var submittingVideoIDs: Set<DownloadTask.ID> = []
    private var videoFFmpegURL: URL?
    private var videoStartupTask: Task<Void, Never>?
    private var videoConfigurationTask: Task<Void, Never>?
    private var videoConfiguration = VideoEngineConfiguration()
    private var started: Set<TaskKind> = []
    private var generation: UUID?
    private var pollingTask: Task<Void, Never>?
    private var applyTask: Task<Void, Never>?
    private var latestOptions: EngineOptions?
    private var pendingAdds: [TaskKind: Int] = [:]
    private var revisions: [TaskKind: Int] = [:]
    private var excludedTaskIDs: [TaskKind: Set<String>] = [:]
    private var isPolling = false
    private var checksumJobs: [UUID: Task<Void, Never>] = [:]
    private var checkedCompletions: Set<UUID> = []
    private var replacingHTTPTasks: Set<UUID> = []
    private var resubmittingTaskIDs: Set<UUID> = []
    private var resubmissionAttempts: [UUID: UUID] = [:]
    private var httpResumeAttempts: [UUID: UUID] = [:]
    private var forgettingHTTPTasks: [UUID: Task<Void, Never>] = [:]
    private var provenanceCompletions: Set<UUID> = []
    private var checkedHTTPFiles: Set<URL> = []
    private var httpFileIssues: [URL: String] = [:]
    private let fileProgressPublisher = DownloadFileProgressPublisher()
    private let scheduling: DownloadScheduling
    private let inspectHTTP: (URL, DownloadRequestContext, Bool) async throws -> HTTPResourceIdentity

    init(
        model: AppModel, engines: [any DownloadEngine], videoBootstrap: VideoEngineBootstrap? = nil,
        videoEngineFactory: (@MainActor (VideoEngineConfiguration) async throws -> any DownloadEngine)? = nil,
        schedulingDefaults: UserDefaults? = nil,
        inspectHTTP: @escaping (URL, DownloadRequestContext, Bool) async throws -> HTTPResourceIdentity = {
            try await HTTPResourceProbe.inspect($0, context: $1, expectsHTML: $2)
        }
    ) {
        self.model = model
        provenanceCompletions = Set(model.activeTasks.filter { [.completed, .seeding, .extracting].contains($0.status) }.map(\.id))
        self.inspectHTTP = inspectHTTP
        scheduling = DownloadScheduling(defaults: schedulingDefaults ?? (AppEnvironment.isRunningUnitTests ? nil : .standard))
        self.engines = engines
        self.videoBootstrap = videoBootstrap
        self.videoEngineFactory = videoEngineFactory
        model.coordinator = self
    }

    func start(options: EngineOptions, videoConfiguration: VideoEngineConfiguration = VideoEngineConfiguration()) async {
        guard generation == nil, !Task.isCancelled else { return }
        let token = UUID()
        generation = token
        latestOptions = options
        scheduling.reset()
        for task in model.tasks where task.deletedAt != nil { excludeFromSnapshots(task) }
        let startupKinds = Set(engines.map(\.kind)).union(
            videoBootstrap != nil || videoEngineFactory != nil ? [.video] : []
        )
        for kind in startupKinds {
            _ = scheduling.startupOptions(options, kind: kind, kinds: startupKinds)
        }
        self.videoConfiguration = videoConfiguration
        // 尚未交给引擎的任务没有会话及可靠的目录记录，重启后明确提示重新下载。
        for index in model.tasks.indices where model.tasks[index].deletedAt == nil && model.tasks[index].kind == .video
            && model.tasks[index].engineTaskID == nil
            && [.queued, .paused].contains(model.tasks[index].status) {
            model.tasks[index].status = .failed
            model.tasks[index].errorMessage = String(localized: "上次退出时视频工具尚未准备好，可以重新下载")
        }
        if videoBootstrap != nil || videoEngineFactory != nil {
            model.engineStates[.video] = .preparing
            videoStartupTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let engine: any DownloadEngine
                    if let factory = self.videoEngineFactory {
                        engine = try await factory(videoConfiguration)
                    } else if let videoBootstrap = self.videoBootstrap {
                        engine = try await videoBootstrap.makeEngine(configuration: videoConfiguration)
                        // 没有 ffmpeg 时引擎照常启动：单文件格式仍能下载，只是不能合并音视频。
                        self.videoFFmpegURL = await videoBootstrap.ffmpegURL
                    } else {
                        return
                    }
                    guard self.generation == token, !Task.isCancelled else { return }
                    // 准备期间设置可能变化；启动前下发最新值。
                    if let video = engine as? YtDlpEngine {
                        try await self.videoConfiguration.apply(to: video)
                    }
                    let startup = self.scheduling.startupOptions(
                        self.latestOptions ?? options, kind: .video,
                        kinds: Set(self.engines.map(\.kind)).union([.video])
                    )
                    try await engine.start(options: startup)
                    await self.removeExcludedVideoTasks(using: engine)
                    guard self.generation == token, !Task.isCancelled else {
                        await engine.stop()
                        return
                    }
                    self.engines.append(engine)
                    self.started.insert(.video)
                    self.model.engineStates[.video] = self.videoBootstrap == nil ? .running : EngineStatusPresentation.videoReadyState(ffmpegURL: self.videoFFmpegURL)
                    self.configureVideo(self.videoConfiguration)
                    await self.refreshScheduling(sample: false)
                    await self.submitWaitingVideos()
                } catch {
                    guard self.generation == token, !Task.isCancelled else { return }
                    let reason = EngineStatusPresentation.errorMessage(error)
                    self.model.engineStates[.video] = .failed(reason)
                    self.failWaitingVideos(reason: reason)
                }
            }
        }
        await withTaskGroup(of: (TaskKind, String?).self) { group in
            for engine in engines {
                let startup = scheduling.startupOptions(options, kind: engine.kind, kinds: startupKinds)
                group.addTask {
                    do {
                        try await engine.start(options: startup)
                        return (engine.kind, nil)
                    } catch {
                        return (engine.kind, EngineStatusPresentation.errorMessage(error, kind: engine.kind))
                    }
                }
            }
            for await (kind, error) in group {
                guard generation == token else { continue }
                if let error {
                    model.engineStates[kind] = .failed(error)
                } else {
                    if kind == .video, let engine = engines.first(where: { $0.kind == .video }) {
                        await removeExcludedVideoTasks(using: engine)
                        guard generation == token else { continue }
                    }
                    started.insert(kind)
                    model.engineStates[kind] = .running
                    if kind == .bittorrent { model.bitTorrent?.start() }
                    if kind == .ed2k { model.ed2k?.start() }
                }
            }
        }
        guard generation == token else {
            // stop 可能发生在 start 等待就绪期间，清理迟到的启动结果。
            await stopEngines()
            return
        }
        if Task.isCancelled {
            await stop()
            return
        }
        if let latestOptions, latestOptions != options {
            apply(options: latestOptions)
        }
        await refreshScheduling(sample: false)
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    return
                }
                guard let self else { return }
                await self.poll()
            }
        }
    }

    func stop() async {
        generation = nil
        model.stalledYieldTaskIDs.removeAll()
        httpResumeAttempts.removeAll()
        for job in forgettingHTTPTasks.values { await job.value }
        forgettingHTTPTasks.removeAll()
        fileProgressPublisher.stop()
        await StreamingPlayback.shared.stop()
        for job in checksumJobs.values { job.cancel() }
        checksumJobs.removeAll()
        model.bitTorrent?.stop()
        model.ed2k?.stop()
        waitingVideoLinks.removeAll()
        pollingTask?.cancel()
        pollingTask = nil
        applyTask?.cancel()
        applyTask = nil
        videoStartupTask?.cancel()
        videoConfigurationTask?.cancel()
        started.removeAll()
        for kind in TaskKind.allCases {
            model.engineStates[kind] = .unavailable
        }
        await stopEngines()
        await videoStartupTask?.value
        videoStartupTask = nil
    }

    func poll() async {
        guard let token = generation, !isPolling else { return }
        isPolling = true
        defer { isPolling = false }
        var snapshots: [TaskKind: [EngineTaskSnapshot]] = [:]
        var snapshotRevisions: [TaskKind: Int] = [:]
        for engine in engines where started.contains(engine.kind) {
            // 添加期间的快照可能尚不含新 GID，不能据此删除刚插入的任务。
            guard pendingAdds[engine.kind, default: 0] == 0 else { continue }
            let revision = revisions[engine.kind, default: 0]
            do {
                let current = try await engine.snapshots()
                guard generation == token else { return }
                if pendingAdds[engine.kind, default: 0] == 0, revisions[engine.kind, default: 0] == revision {
                    snapshots[engine.kind] = current
                    snapshotRevisions[engine.kind] = revision
                }
            } catch {
                guard generation == token else { return }
                model.engineStates[engine.kind] = .failed(EngineStatusPresentation.errorMessage(error))
            }
        }
        guard generation == token else { return }
        snapshots = snapshots.filter { kind, _ in
            pendingAdds[kind, default: 0] == 0 && revisions[kind, default: 0] == snapshotRevisions[kind]
        }
        for kind in snapshots.keys {
            snapshots[kind]?.removeAll { excludedTaskIDs[kind, default: []].contains($0.engineTaskID) }
            if kind == .video {
                snapshots[kind]?.removeAll { model.excludedVideoTaskIDs.contains($0.engineTaskID) }
            }
        }
        if let http = snapshots[.http] {
            snapshots[.http] = await validateHTTPCompletions(http)
            guard generation == token else { return }
            snapshots = snapshots.filter { kind, _ in
                pendingAdds[kind, default: 0] == 0 && revisions[kind, default: 0] == snapshotRevisions[kind]
            }
        }
        let mergeInput = model.tasks
        var merged = EngineSnapshotMerger.merge(
            tasks: mergeInput, snapshots: snapshots, now: .now, videoConfiguration: videoConfiguration
        )
        let previousTasks = Dictionary(mergeInput.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in merged.indices {
            let task = merged[index]
            guard let previous = previousTasks[task.id] else { continue }
            let reasons = model.automaticPauseReasons(for: previous)
            if !reasons.isEmpty, task.deletedAt == nil, ![.completed, .extracting].contains(previous.status) {
                merged[index].pauseReason = model.automaticPauseStore.isManuallyPaused(previous)
                    ? nil : model.automaticPauseStore.displayReason(for: previous)
                merged[index].status = .paused
                merged[index].downloadRate = 0
                merged[index].uploadRate = 0
            }
        }
        // 在发布完成状态前写来源，自动解压不会抢先拿走原压缩包。
        var newCompletions: [DownloadTask] = []
        for task in merged where [.completed, .seeding].contains(task.status) && task.deletedAt == nil {
            guard let file = task.savePath, !IncompleteHTTPTransfer.isStagingFile(file),
                  !provenanceCompletions.contains(task.id) else { continue }
            await DownloadProvenance.apply(to: file, task: task)
            guard generation == token else { return }
            newCompletions.append(task)
        }
        // 写属性期间允许用户操作；有新操作时留给下一轮重新合并。
        guard model.tasks == mergeInput, snapshots.keys.allSatisfy({ revisions[$0, default: 0] == snapshotRevisions[$0] }) else { return }
        provenanceCompletions.formUnion(newCompletions.map(\.id))
        model.tasks = merged
        for task in newCompletions { model.completionShortcutRunner?.completed(task) }
        // 重启或迟到快照可能仍在写盘；保护状态必须同时落实到引擎。
        for task in model.activeTasks where task.status == .paused && !model.automaticPauseReasons(for: task).isEmpty {
            if let snapshot = snapshots[task.kind]?.first(where: { $0.engineTaskID == task.engineTaskID }),
               [.downloading, .queued, .waitingForSources, .postProcessing, .seeding].contains(snapshot.status) {
                await pause(task.id)
                guard generation == token else { return }
            }
        }
        await publishFileProgress()
        captureCompletedBookmarks()
        checkCompletedFiles()
        if let selected = model.selectedTaskID, !model.tasks.contains(where: { $0.id == selected }) {
            model.selectedTaskID = nil
        }
        await refreshScheduling()
        guard generation == token else { return }
        model.bitTorrent?.observePeers(in: model.tasks)
        model.downloadRateHistory = EngineSnapshotMerger.appendingRate(model.totalDownloadRate, to: model.downloadRateHistory)
    }

    func add(
        links: [ParsedLink], autoExtract: Bool, directory: URL? = nil,
        filePriorities: [ParsedLink: [Int]] = [:],
        torrentDownloadModes: [ParsedLink: (sequentialDownload: Bool, firstLastPriority: Bool)] = [:],
        videoEntries: [ParsedLink: YtDlpPlaylistEntry] = [:],
        requestContexts: [ParsedLink: DownloadRequestContext] = [:],
        checksums: [ParsedLink: DownloadChecksum] = [:],
        videoFormatIDs: [ParsedLink: String] = [:],
        videoOnlyFormats: [ParsedLink: Bool] = [:],
        videoOptions: [ParsedLink: YtDlpTaskOptions] = [:],
        videoIdentities: [ParsedLink: String] = [:]
    ) async {
        var insertionIndex = 0
        for link in links {
            if link.kind == .bittorrent, let hash = NewTaskLinkModel(link: link).infoHash,
               NewTaskLinkModel.existingTorrent(infoHash: hash, tasks: model.tasks.filter { $0.deletedAt != nil }) != nil {
                model.openURLIssue = String(localized: "这个种子已在最近删除里，请恢复任务，或彻底删除后再添加。")
                continue
            }
            var task = DownloadTask(link: link, autoExtract: autoExtract)
            let lastPosition = model.activeTasks.compactMap(\.queuePosition).max() ?? 0
            task.queuePosition = lastPosition < Int64.max ? lastPosition + 1 : Int64.max
            task.videoIdentity = videoIdentities[link]
            task.requestContext = requestContexts[link]?.withoutCookie
            task.videoOptions = videoOptions[link]
            task.checksum = checksums[link]
            if link.kind == .http, let name = requestContexts[link]?.suggestedFilename {
                task.name = name
                task.fileExtension = URL(fileURLWithPath: name).pathExtension
            }
            if let entry = videoEntries[link] { task.name = entry.taskTitle }
            let ruleResult = applyDownloadRule(to: &task, link: link, context: requestContexts[link] ?? .init(), directory: directory)
            if task.kind == .http { task.downloadLimit = ruleResult.rule?.speedLimitBytes }
            let directory = ruleResult.directory
            if let saveDirectory = directory ?? latestOptions?.downloadDirectory {
                task.writeDirectories = [saveDirectory]
            }
            let requestContext = ruleResult.context
            if let detail = videoConfiguration.detail(for: link) {
                task.detail = detail
            }
            if scheduleRequiresPause() { task.pauseReason = .schedule }
            if link.kind == .video, videoBootstrap != nil || videoEngineFactory != nil || engine(for: .video) != nil {
                task.status = .queued
                model.tasks.insert(task, at: min(insertionIndex, model.tasks.count))
                if insertionIndex == 0 { model.selectedTaskID = task.id }
                insertionIndex += 1
                waitingVideoLinks[task.id] = (link, directory, videoEntries[link], videoFormatIDs[link], videoOnlyFormats[link] ?? false)
                if engine(for: .video) != nil {
                    await submitWaitingVideos()
                } else if case .failed(let reason) = model.engineStates[.video] {
                    failWaitingVideos(reason: reason)
                }
                continue
            }
            task.status = .engineUnavailable
            if let engine = engine(for: link.kind) {
                pendingAdds[link.kind, default: 0] += 1
                do {
                    var queued = task.pauseReason != nil || shouldQueueNewTask()
                    if let http = engine as? Aria2Engine {
                        let context = requestContext
                        try context.validate()
                        if case .http(let url, _, _) = link {
                            let name = context.suggestedFilename ?? url.lastPathComponent
                            if !name.isEmpty, name != "/" {
                                task.savePath = (directory ?? latestOptions?.downloadDirectory)?.appendingPathComponent(name)
                            }
                        }
                        if let cookie = context.requestCookie {
                            try await DownloadRequestCookieStore.shared.save(cookie, taskID: task.id)
                            task.hasRequestCookie = true
                        }
                        if case .http(let url, _, _) = link, !HTTPMetalink.recognizes(url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                            do {
                                task.httpIdentity = try await HTTPResourceProbe.inspect(
                                    url, context: context, expectsHTML: ["html", "htm"].contains(url.pathExtension.lowercased())
                                )
                            } catch let failure as HTTPDownloadFailure {
                                throw failure
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                // 预检网络失败时仍让 aria2 执行其重试策略；换链时必须取得可比对身份。
                            }
                        }
                        if scheduleRequiresPause() {
                            task.pauseReason = .schedule
                            queued = true
                        }
                        task.engineTaskID = try await http.add(
                            link: link, directory: directory, context: context, checksum: task.checksum, paused: queued,
                            httpThreads: ruleResult.rule?.httpThreads, speedLimitBytes: ruleResult.rule?.speedLimitBytes,
                            incompleteTaskID: (model.downloadSettings?.markIncomplete ?? true) ? task.id : nil
                        )
                    } else if let torrent = engine as? TorrentEngine {
                        let mode = torrentDownloadModes[link]
                        let id = try await torrent.add(
                            link: link, directory: directory, filePriorities: filePriorities[link], paused: queued || mode != nil,
                            markIncomplete: model.downloadSettings?.markIncomplete ?? true
                        )
                        task.engineTaskID = id
                        if let mode {
                            try await torrent.setDownloadMode(
                                id, sequentialDownload: mode.sequentialDownload, firstLastPriority: mode.firstLastPriority
                            )
                            if !queued { try await torrent.resume(id) }
                        }
                    } else if queued {
                        task.engineTaskID = try await engine.addQueued(link: link, directory: directory)
                    } else {
                        task.engineTaskID = try await engine.add(link: link, directory: directory)
                    }
                    if task.kind == .bittorrent, let id = task.engineTaskID {
                        excludedTaskIDs[.bittorrent]?.remove(id)
                    }
                    if scheduleRequiresPause() { task.pauseReason = .schedule }
                    if task.pauseReason != nil, !queued, let engineID = task.engineTaskID {
                        try await engine.pause(engineID)
                    }
                    if queued && task.pauseReason == nil { scheduling.queue(task) }
                    task.status = task.pauseReason == nil ? .queued : .paused
                } catch {
                    task.status = .failed
                    task.errorMessage = EngineStatusPresentation.errorMessage(error)
                }
                pendingAdds[link.kind, default: 0] -= 1
                revisions[link.kind, default: 0] += 1
            } else if engines.contains(where: { $0.kind == link.kind }) || (link.kind == .video && videoBootstrap != nil) {
                task.status = .failed
                if case .failed(let reason) = model.engineStates[link.kind] {
                    task.errorMessage = reason
                } else {
                    task.errorMessage = String(localized: "下载引擎未运行")
                }
            }
            if task.kind == .http {
                task.detail = .http(connections: 0)
            }
            model.tasks.insert(task, at: min(insertionIndex, model.tasks.count))
            if insertionIndex == 0 {
                model.selectedTaskID = task.id
            }
            insertionIndex += 1
        }
        await refreshScheduling(sample: false)
    }

    func pause(_ id: DownloadTask.ID) async {
        await perform(id, action: .pause)
    }

    func resume(_ id: DownloadTask.ID) async {
        await perform(id, action: .resume)
    }

    func setChecksum(_ id: UUID, checksum: DownloadChecksum?) async throws {
        guard let task = model.tasks.first(where: { $0.id == id }) else { return }
        if task.kind == .http, let engineID = task.engineTaskID,
           ![.completed, .failed].contains(task.status), let engine = engine(for: .http) as? Aria2Engine {
            pendingAdds[.http, default: 0] += 1
            defer {
                pendingAdds[.http, default: 0] -= 1
                revisions[.http, default: 0] += 1
            }
            let updatedID = try await engine.setChecksum(engineID, checksum: checksum)
            guard model.tasks.contains(where: { $0.id == id }) else {
                if updatedID != engineID { try await engine.remove(updatedID, deleteFiles: false) }
                return
            }
            if updatedID != engineID, let index = model.tasks.firstIndex(where: { $0.id == id }) {
                excludeFromSnapshots(task)
                model.tasks[index].engineTaskID = updatedID
                if task.status != .paused {
                    model.tasks[index].status = .queued
                    scheduling.queue(model.tasks[index])
                }
            }
        }
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        checksumJobs[id]?.cancel()
        checksumJobs[id] = nil
        checkedCompletions.remove(id)
        model.tasks[index].checksum = checksum
        model.tasks[index].checksumVerification = nil
        checkCompletedFiles()
        await refreshScheduling(sample: false)
    }

    func refreshHTTPProxy() async throws {
        guard let http = engine(for: .http) as? Aria2Engine else { return }
        try await http.refreshProxy()
    }

    func httpStreamingEngine() -> Aria2Engine? {
        engine(for: .http) as? Aria2Engine
    }

    func retryHTTPAuthentication(_ id: UUID, credential: HTTPCredentialStore.Credential) async throws {
        guard let task = model.tasks.first(where: { $0.id == id && $0.deletedAt == nil }), task.kind == .http,
              HTTPDownloadFailure.requiresCredentials(status: task.status, message: task.httpValidationError ?? task.errorMessage),
              let url = URL(string: task.sourceLink), let host = url.host else { throw EngineError.unsupportedLink }
        try await Task.detached { try HTTPCredentialStore.save(credential, host: host) }.value
        guard let index = model.tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { throw CancellationError() }
        model.tasks[index].hasHTTPCredentials = true
        var context = task.requestContext ?? DownloadRequestContext()
        context.usesStoredHTTPCredentials = true
        // 换链通道会预检最终主机并剥离跨站认证；停态 GID 也由该通道安全重建。
        try await replaceHTTPLink(id, newURL: url, requestContext: context)
    }

    func addHTTPMirror(_ id: UUID, url: URL) async throws {
        guard let task = model.tasks.first(where: { $0.id == id && $0.deletedAt == nil }), task.kind == .http,
              task.status == .downloading, let engineID = task.engineTaskID,
              let http = engine(for: .http) as? Aria2Engine else { throw EngineError.notRunning }
        guard let identity = task.httpIdentity else { throw HTTPDownloadFailure.unknownIdentity }
        try await http.addMirror(engineID, url: url, original: identity, context: task.requestContext ?? .init())
    }

    func replaceHTTPLink(
        _ id: UUID, newURL: URL, restartFromScratch: Bool = false, requestContext: DownloadRequestContext? = nil
    ) async throws {
        guard let task = model.tasks.first(where: { $0.id == id }), task.kind == .http,
              let http = engine(for: .http) as? Aria2Engine else { throw EngineError.notRunning }
        guard replacingHTTPTasks.insert(id).inserted else { return }
        defer { replacingHTTPTasks.remove(id) }
        let token = generation
        var context = task.requestContext ?? DownloadRequestContext()
        context.usesStoredHTTPCredentials = task.hasHTTPCredentials
        let previous = URL(string: task.sourceLink)
        let sameOrigin = previous?.host == newURL.host && previous?.scheme == newURL.scheme && previous?.port == newURL.port
        if sameOrigin, task.hasRequestCookie == true {
            context.cookie = try await DownloadRequestCookieStore.shared.load(taskID: id)
        } else if !sameOrigin {
            // 用户换到别的网站时，不把原网站的登录凭据发过去。
            context = context.withoutCookie
            context.usesStoredHTTPCredentials = false
            context.headers = context.headers.filter { !["authorization", "proxy-authorization"].contains($0.key.lowercased()) }
        }
        if let requestContext {
            try requestContext.validate()
            context.referer = requestContext.referer
            context.userAgent = requestContext.userAgent
            if sameOrigin { context.usesStoredHTTPCredentials = requestContext.usesStoredHTTPCredentials }
            if let cookie = requestContext.requestCookie { context.cookie = cookie }
        }
        let identity = try await HTTPResourceProbe.inspect(
            newURL, context: context, expectsHTML: task.httpIdentity?.contentType == "text/html"
                || ["html", "htm"].contains(task.savePath?.pathExtension.lowercased() ?? "")
        )
        let isFirstAuthentication = task.hasHTTPCredentials == true && task.httpIdentity == nil && task.totalBytes == nil
            && HTTPDownloadFailure.requiresCredentials(status: task.status, message: task.httpValidationError ?? task.errorMessage)
        if !restartFromScratch, !isFirstAuthentication {
            let original = task.httpIdentity ?? HTTPResourceIdentity(size: task.totalBytes)
            try original.validateReplacement(identity)
        }
        guard generation == token, !Task.isCancelled,
              model.tasks.contains(where: { $0.id == id && $0.engineTaskID == task.engineTaskID && $0.checksum == task.checksum }) else {
            throw CancellationError()
        }
        pendingAdds[.http, default: 0] += 1
        revisions[.http, default: 0] += 1
        defer {
            pendingAdds[.http, default: 0] -= 1
            revisions[.http, default: 0] += 1
        }
        let engineID: String
        if let oldID = task.engineTaskID {
            engineID = try await http.replaceURI(oldID, with: newURL, context: context, checksum: task.checksum, restartFromScratch: restartFromScratch)
        } else {
            if let file = task.savePath { context.suggestedFilename = file.lastPathComponent }
            engineID = try await http.add(
                link: .http(url: newURL, decodedFromThunder: false, original: newURL.absoluteString),
                directory: task.savePath?.deletingLastPathComponent(), context: context, checksum: task.checksum, paused: true,
                incompleteTaskID: (model.downloadSettings?.markIncomplete ?? true) ? task.id : nil
            )
        }
        guard generation == token, let index = model.tasks.firstIndex(where: { $0.id == id }) else {
            try await http.remove(engineID, deleteFiles: false)
            return
        }
        if let oldID = task.engineTaskID, oldID != engineID { excludeFromSnapshots(task) }
        model.tasks[index].engineTaskID = engineID
        model.tasks[index].sourceLink = newURL.absoluteString
        model.tasks[index].requestContext = context.withoutCookie
        model.tasks[index].hasHTTPCredentials = context.usesStoredHTTPCredentials
        model.tasks[index].httpIdentity = identity
        model.tasks[index].httpValidationError = nil
        model.tasks[index].checksumVerification = nil
        model.tasks[index].errorMessage = nil
        model.tasks[index].completedAt = nil
        model.tasks[index].status = .queued
        if restartFromScratch { model.tasks[index].receivedBytes = 0 }
        if let file = task.savePath {
            checkedHTTPFiles.remove(file)
            httpFileIssues[file] = nil
        }
        checksumJobs[id]?.cancel()
        checksumJobs[id] = nil
        checkedCompletions.remove(id)
        scheduling.queue(model.tasks[index])
        if let cookie = requestContext?.requestCookie {
            try await DownloadRequestCookieStore.shared.save(cookie, taskID: id)
            model.tasks[index].hasRequestCookie = true
        } else if !sameOrigin, task.hasRequestCookie == true {
            model.tasks[index].hasRequestCookie = false
            try await DownloadRequestCookieStore.shared.delete(taskID: id)
        }
        await refreshScheduling(sample: false)
    }

    /// 在发布完成状态前识别登录页，避免把网页当成成品发通知或交给解压。
    private func validateHTTPCompletions(_ snapshots: [EngineTaskSnapshot]) async -> [EngineTaskSnapshot] {
        var result = snapshots
        let http = engines.first { $0.kind == .http } as? Aria2Engine
        let token = generation
        for index in result.indices where result[index].status == .completed {
            guard let file = result[index].savePath else { continue }
            let task = model.tasks.first { $0.kind == .http && $0.engineTaskID == result[index].engineTaskID }
            do {
                if !checkedHTTPFiles.contains(file) {
                    if task?.httpIdentity?.contentType != "text/html", !["html", "htm"].contains(file.pathExtension.lowercased()) {
                        try await HTTPResourceProbe.validateDownloadedFile(file)
                    }
                    checkedHTTPFiles.insert(file)
                }
                if let expected = task?.checksum {
                    let verification: ChecksumVerification
                    if let saved = task?.checksumVerification, saved.expected == expected, saved.actual != nil {
                        verification = saved
                    } else {
                        verification = try await ChecksumVerifier.verify(file: file, expected: expected)
                        guard generation == token, task == nil || model.tasks.contains(where: {
                            $0.id == task?.id && $0.deletedAt == nil && $0.engineTaskID == task?.engineTaskID
                                && $0.checksum == expected
                        }) else { continue }
                        if let taskIndex = model.tasks.firstIndex(where: { $0.id == task?.id }) {
                            model.tasks[taskIndex].checksumVerification = verification
                        }
                    }
                    guard verification.matches == true else {
                        throw EngineError.invalidResponse("校验值不一致，未完成文件已保留，请重新下载。")
                    }
                }
                guard generation == token, task == nil || model.tasks.contains(where: {
                    $0.id == task?.id && $0.deletedAt == nil && $0.engineTaskID == task?.engineTaskID
                        && $0.checksum == task?.checksum
                }) else { continue }
                if let issue = httpFileIssues[file] { throw EngineError.invalidResponse(issue) }
                if let http {
                    let destination = try await http.finalizeIncomplete(result[index].engineTaskID, file: file)
                    result[index].savePath = destination
                    result[index].name = destination.lastPathComponent
                    result[index].writeDirectories = [destination.deletingLastPathComponent()]
                    checkedHTTPFiles.insert(destination)
                }
            } catch {
                result[index].status = .failed
                result[index].errorMessage = EngineStatusPresentation.errorMessage(error)
                // 目标冲突可重试；内容检查失败保留原因，不能在后续快照中漏过。
                if error is HTTPDownloadFailure { httpFileIssues[file] = error.localizedDescription }
            }
        }
        return result
    }

    private func publishFileProgress() async {
        var files: [UUID: [TorrentFileEntry]] = [:]
        if let torrent = engine(for: .bittorrent) as? TorrentEngine {
            for task in model.activeTasks where task.kind == .bittorrent && task.status == .downloading {
                if let id = task.engineTaskID { files[task.id] = try? await torrent.files(id) }
            }
        }
        fileProgressPublisher.update(tasks: model.tasks, torrentFiles: files)
    }

    private func applyDownloadRule(
        to task: inout DownloadTask, link: ParsedLink, context: DownloadRequestContext, directory: URL?
    ) -> (directory: URL?, context: DownloadRequestContext, rule: DownloadRule?) {
        let settings = model.downloadSettings
        let root = directory ?? latestOptions?.downloadDirectory
        let rule = DownloadRule.firstMatch(
            in: settings?.downloadRules ?? [], context: context, downloadURL: URL(string: link.original),
            filename: task.name, kind: task.kind
        )
        var context = context
        if task.kind == .http, let userAgent = rule?.userAgent, !userAgent.isEmpty { context.userAgent = userAgent }
        task.requestContext = context.withoutCookie
        let fileExtension = task.fileExtension ?? URL(filePath: task.name).pathExtension
        var destination = root
        if let root, let ruleDirectory = rule?.saveDirectory(under: root) {
            destination = ruleDirectory
        } else if settings?.sortIntoFolders == true, let root,
                  let category = DownloadCategory.classify(extension: fileExtension) {
            destination = root.appendingPathComponent(category.folderName, isDirectory: true)
        }
        if let destination, destination != root {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            } catch {
                task.errorMessage = error.localizedDescription
            }
        }
        task.writeDirectories = destination.map { [$0] }
        return (destination, context, rule)
    }

    private func captureCompletedBookmarks() {
        var tasks = model.tasks
        var changed = false
        for index in tasks.indices where tasks[index].deletedAt == nil && tasks[index].fileBookmark == nil
            && [.completed, .seeding].contains(tasks[index].status) {
            let original = tasks[index]
            FileTracker.capture(&tasks[index])
            changed = changed || tasks[index] != original
        }
        if changed { model.tasks = tasks }
    }

    /// 所有引擎共用完成后的流式校验，不阻塞轮询或主线程。
    private func checkCompletedFiles() {
        let currentIDs = Set(model.activeTasks.map(\.id))
        for id in checksumJobs.keys where !currentIDs.contains(id) {
            checksumJobs[id]?.cancel()
            checksumJobs[id] = nil
        }
        checkedCompletions.formIntersection(currentIDs)
        for index in model.tasks.indices {
            if let issue = model.tasks[index].httpValidationError {
                model.tasks[index].status = .failed
                model.tasks[index].errorMessage = issue
            }
        }
        for task in model.tasks where task.deletedAt == nil && ([.completed, .seeding].contains(task.status)
            || (task.kind == .http && task.status == .failed && task.checksum != nil
                && (task.errorMessage?.contains("校验值不一致") == true
                    || task.totalBytes.map { $0 > 0 && task.receivedBytes >= $0 } == true))) {
            guard let file = task.savePath, !checkedCompletions.contains(task.id), checksumJobs[task.id] == nil else { continue }
            if let result = task.checksumVerification, result.actual != nil, result.expected == task.checksum {
                checkedCompletions.insert(task.id)
                continue
            }
            let id = task.id
            let token = generation
            checksumJobs[id] = Task { [weak self] in
                var expected = task.checksum
                var verification: ChecksumVerification?
                do {
                    if expected == nil { expected = try await ChecksumVerifier.discover(for: file) }
                    if let expected { verification = try await ChecksumVerifier.verify(file: file, expected: expected) }
                } catch is CancellationError {
                    return
                } catch {
                    if let expected {
                        verification = ChecksumVerification(expected: expected, errorMessage: "无法读取文件进行校验，请检查文件是否仍在原位置。")
                    }
                }
                guard let self, !Task.isCancelled, self.generation == token else { return }
                self.checksumJobs[id] = nil
                guard let index = self.model.tasks.firstIndex(where: { $0.id == id && $0.savePath == file && $0.checksum == task.checksum }) else { return }
                self.checkedCompletions.insert(id)
                self.model.tasks[index].checksum = expected
                self.model.tasks[index].checksumVerification = verification
                if file.pathExtension.lowercased() == "sha256" || file.lastPathComponent == "SHA256SUMS" {
                    // 校验清单可能比成品晚下完；清单完成后让同目录的成品再识别一次。
                    for other in self.model.tasks where other.id != id && other.checksum == nil
                        && other.savePath?.deletingLastPathComponent() == file.deletingLastPathComponent() {
                        self.checkedCompletions.remove(other.id)
                    }
                }
            }
        }
    }

    func diskProtectionDirectory(for id: DownloadTask.ID) -> URL? {
        waitingVideoLinks[id]?.directory ?? latestOptions?.downloadDirectory
    }

    /// 磁盘保护使用独立入口，不能把用户原本暂停的任务标为可自动恢复。
    func pauseForDiskSpace(_ id: DownloadTask.ID) async {
        await model.pauseAutomatically(id, reason: .diskSpace)
    }

    func resumeAfterDiskSpace(_ id: DownloadTask.ID) async {
        await model.resumeAutomatically(id, reason: .diskSpace)
    }

    func remove(_ id: DownloadTask.ID, deleteFiles: Bool = false) async {
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        let task = model.tasks[index]
        StreamingPlayback.shared.cancel(id)
        waitingVideoLinks[id] = nil
        if task.kind == .video, task.status == .completed, !deleteFiles {
            await removeCompletedVideo(task).value
            return
        }
        if (task.status == .completed && ![.bittorrent, .ed2k].contains(task.kind)) || task.engineTaskID == nil {
            excludeFromSnapshots(task)
            scheduling.removed(task)
            if deleteFiles { model.removeRecord(id) } else { model.trashRecord(id) }
            return
        }
        guard let engine = engine(for: task.kind), let engineTaskID = task.engineTaskID else {
            setError(String(localized: "下载引擎未运行"), for: id)
            return
        }
        let wasSelected = model.selectedTaskID == id
        excludeFromSnapshots(task)
        if deleteFiles { model.removeRecord(id) } else { model.trashRecord(id) }
        revisions[task.kind, default: 0] += 1
        defer { revisions[task.kind, default: 0] += 1 }
        do {
            try await engine.remove(engineTaskID, deleteFiles: deleteFiles)
            await publishFileProgress()
            scheduling.removed(task)
        } catch {
            excludedTaskIDs[task.kind]?.remove(engineTaskID)
            var restored = task
            restored.errorMessage = EngineStatusPresentation.errorMessage(error)
            if let current = model.tasks.firstIndex(where: { $0.id == id }) {
                model.tasks[current] = restored
            } else {
                model.tasks.insert(restored, at: min(index, model.tasks.count))
            }
            if wasSelected {
                model.selectedTaskID = id
            }
        }
    }

    /// 彻底删除和过期清理不触碰文件，但必须移除引擎的完成结果。
    func forgetHTTPTransfer(_ task: DownloadTask) {
        guard task.kind == .http, let id = task.engineTaskID else { return }
        excludeFromSnapshots(task)
        guard let http = engines.first(where: { $0.kind == .http }) as? Aria2Engine else { return }
        forgettingHTTPTasks[task.id] = Task {
            do { try await http.forgetTransfer(id) }
            catch { model.taskHistoryIssue = EngineStatusPresentation.errorMessage(error) }
        }
    }

    /// 同步保存删除意图并移除列表；引擎失败不能撤销用户删除，也不能删除成品。
    @discardableResult
    func removeCompletedVideo(_ task: DownloadTask) -> Task<Void, Never> {
        model.excludeVideoFromHistory(task)
        excludeFromSnapshots(task)
        scheduling.removed(task)
        model.trashRecord(task.id)
        model.flushTaskHistory()
        return Task {
            guard let id = task.engineTaskID, let engine = engine(for: .video) else { return }
            try? await engine.remove(id, deleteFiles: false)
        }
    }

    private func removeExcludedVideoTasks(using engine: any DownloadEngine) async {
        for id in model.excludedVideoTaskIDs {
            // 保留排除标记，覆盖迟到的旧快照及引擎写盘失败；下次启动仍可补删。
            try? await engine.remove(id, deleteFiles: false)
        }
    }

    /// 已删除的记录不再从仍在返回旧结果的引擎中重新导入。
    func excludeFromSnapshots(_ task: DownloadTask) {
        guard let id = task.engineTaskID else { return }
        excludedTaskIDs[task.kind, default: []].insert(id)
    }

    func apply(options: EngineOptions) {
        latestOptions = options
        applyTask?.cancel()
        applyTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(0.5))
            } catch {
                return
            }
            guard let self, let token = self.generation else { return }
            guard self.generation == token else { return }
            await self.refreshScheduling(sample: false)
        }
    }

    func configureVideo(_ configuration: VideoEngineConfiguration) {
        videoConfiguration = configuration
        let previous = videoConfigurationTask
        videoConfigurationTask = Task { [weak self] in
            await previous?.value
            guard let self, let token = self.generation, !Task.isCancelled,
                  let engine = self.engines.first(where: { $0.kind == .video }) as? YtDlpEngine else { return }
            do {
                try await configuration.apply(to: engine)
                guard self.generation == token, !Task.isCancelled else { return }
                self.model.engineStates[.video] = EngineStatusPresentation.videoReadyState(ffmpegURL: self.videoFFmpegURL)
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.model.engineStates[.video] = .failed(EngineStatusPresentation.errorMessage(error))
            }
        }
    }

    private enum Action {
        case pause
        case resume
    }

    private func perform(_ id: DownloadTask.ID, action: Action) async {
        guard let task = model.tasks.first(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        if action == .resume, resubmittingTaskIDs.contains(id) || !model.automaticPauseReasons(for: task).isEmpty { return }
        if action == .resume, scheduleRequiresPause() {
            if let index = model.tasks.firstIndex(where: { $0.id == id }), model.tasks[index].pauseReason != .diskSpace {
                model.tasks[index].pauseReason = .schedule
                await pause(id)
            }
            return
        }
        if action == .pause { resubmissionAttempts[id] = nil }
        let resumeAttempt = UUID()
        if task.kind == .http {
            httpResumeAttempts[id] = action == .resume ? resumeAttempt : nil
        }
        let token = generation
        if action == .resume, task.engineTaskID == nil, waitingVideoLinks[id] == nil {
            await resubmit(task, token: token, resumeAttempt: resumeAttempt)
            return
        }
        if let engineTaskID = task.engineTaskID {
            guard let engine = engine(for: task.kind) else {
                setError(String(localized: "下载引擎未运行"), for: id)
                return
            }
            do {
                revisions[task.kind, default: 0] += 1
                switch action {
                case .pause:
                    let wasQueued = scheduling.isQueuePaused(task)
                    scheduling.userPause(task)
                    do {
                        try await engine.pause(engineTaskID)
                    } catch {
                        if wasQueued { scheduling.queue(task) }
                        else { scheduling.userResume(task) }
                        throw error
                    }
                case .resume:
                    if task.kind == .http, let identity = task.httpIdentity,
                       let url = URL(string: task.sourceLink), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                        var context = task.requestContext ?? DownloadRequestContext()
                        if task.hasRequestCookie == true {
                            context.cookie = try await DownloadRequestCookieStore.shared.load(taskID: id)
                        }
                        let current = try await inspectHTTP(url, context, identity.contentType == "text/html")
                        guard generation == token, httpResumeAttempts[id] == resumeAttempt,
                              !model.userPausedTaskIDs.contains(id),
                              model.tasks.contains(where: {
                                  $0.id == id && $0.deletedAt == nil && $0.engineTaskID == engineTaskID && $0.status == task.status
                              }) else { return }
                        try identity.validateReplacement(current)
                    }
                    scheduling.userResume(task)
                    if let total = task.totalBytes, total > 0, task.receivedBytes >= total {
                        try await engine.resume(engineTaskID)
                    } else {
                        // 由统一队列决定何时恢复，不能从手动恢复入口绕过并发上限。
                        scheduling.queue(task)
                    }
                }
                revisions[task.kind, default: 0] += 1
            } catch {
                if task.kind == .http, action == .resume,
                   (generation != token || httpResumeAttempts[id] != resumeAttempt || model.userPausedTaskIDs.contains(id)) { return }
                setError(EngineStatusPresentation.errorMessage(error), for: id)
                if let failure = error as? HTTPDownloadFailure,
                   let index = model.tasks.firstIndex(where: { $0.id == id }) {
                    model.tasks[index].httpValidationError = failure.localizedDescription
                    model.tasks[index].status = .failed
                }
                return
            }
        }
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        if action == .resume, !model.automaticPauseReasons(for: model.tasks[index]).isEmpty || model.userPausedTaskIDs.contains(id) {
            await pause(id)
            return
        }
        switch action {
        case .pause:
            model.tasks[index].status = .paused
            model.tasks[index].downloadRate = 0
            model.tasks[index].uploadRate = 0
            model.tasks[index].estimatedTimeRemaining = nil
            model.tasks[index].errorMessage = nil
            await publishFileProgress()
        case .resume:
            model.tasks[index].status = waitingVideoLinks[id] != nil ? .queued
                : task.engineTaskID == nil ? (task.kind == .ed2k ? .waitingForSources : .downloading) : .queued
            if let total = task.totalBytes, total > 0, task.receivedBytes >= total {
                if task.kind == .bittorrent { model.tasks[index].status = .seeding }
                if task.kind == .ed2k { model.tasks[index].status = .completed }
            }
            model.tasks[index].errorMessage = nil
            if waitingVideoLinks[id] != nil { await submitWaitingVideos() }
        }
        await refreshScheduling(sample: false)
    }

    private func resubmit(_ task: DownloadTask, token: UUID?, resumeAttempt: UUID) async {
        let id = task.id
        guard resubmittingTaskIDs.insert(id).inserted else { return }
        resubmissionAttempts[id] = resumeAttempt
        defer {
            resubmittingTaskIDs.remove(id)
            resubmissionAttempts[id] = nil
        }
        guard let engine = engine(for: task.kind) else {
            resubmissionFailed(String(localized: "下载引擎尚未运行，任务仍处于暂停状态；请稍后重试。"), id: id)
            return
        }
        guard let link = LinkParser.parse(task.sourceLink).first(where: { $0.kind == task.kind }) else {
            resubmissionFailed(String(localized: "找不到任务的原始链接，尚未恢复下载；请重新添加原始链接。"), id: id)
            return
        }
        pendingAdds[task.kind, default: 0] += 1
        revisions[task.kind, default: 0] += 1
        defer {
            pendingAdds[task.kind, default: 0] -= 1
            revisions[task.kind, default: 0] += 1
        }
        do {
            var directory = task.savePath?.deletingLastPathComponent() ?? task.writeDirectories?.first
                ?? latestOptions?.downloadDirectory
            var retainedIncomplete = false
            if task.kind == .http, let working = directory,
               working.lastPathComponent == id.uuidString,
               working.deletingLastPathComponent().lastPathComponent == ".mulee-incomplete" {
                directory = working.deletingLastPathComponent().deletingLastPathComponent()
                retainedIncomplete = true
            }
            if task.kind == .http, let directory {
                let retained = IncompleteHTTPTransfer(taskID: id, destination: directory)
                retainedIncomplete = retainedIncomplete || FileManager.default.fileExists(atPath: retained.directory.path)
            }
            let engineID: String
            if let http = engine as? Aria2Engine {
                var context = task.requestContext ?? DownloadRequestContext()
                if task.hasRequestCookie == true {
                    context.cookie = try await DownloadRequestCookieStore.shared.load(taskID: id)
                }
                // 使用原文件名和任务 ID，aria2 才会读回保留的分块及控制文件。
                if retainedIncomplete { context.suggestedFilename = task.savePath?.lastPathComponent }
                if let identity = task.httpIdentity, case .http(let url, _, _) = link,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    let current = try await inspectHTTP(url, context, identity.contentType == "text/html")
                    try identity.validateReplacement(current)
                }
                guard generation == token, httpResumeAttempts[id] == resumeAttempt,
                      !model.userPausedTaskIDs.contains(id),
                      model.tasks.contains(where: { $0.id == id && $0.deletedAt == nil && $0.engineTaskID == nil }) else { return }
                engineID = try await http.add(
                    link: link, directory: directory, context: context, checksum: task.checksum, paused: true,
                    incompleteTaskID: retainedIncomplete || (model.downloadSettings?.markIncomplete ?? true) ? id : nil
                )
            } else if let torrent = engine as? TorrentEngine {
                engineID = try await torrent.add(
                    link: link, directory: task.writeDirectories?.first ?? directory, filePriorities: nil, paused: true,
                    markIncomplete: model.downloadSettings?.markIncomplete ?? true
                )
            } else if let video = engine as? YtDlpEngine {
                engineID = try await video.add(link: link, directory: directory, entry: nil, paused: true, outputOptions: task.videoOptions)
            } else {
                engineID = try await engine.addQueued(link: link, directory: directory)
            }
            guard generation == token, let index = model.tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else {
                try await engine.remove(engineID, deleteFiles: false)
                return
            }
            model.tasks[index].engineTaskID = engineID
            excludedTaskIDs[task.kind]?.remove(engineID)
            if model.userPausedTaskIDs.contains(id) || resubmissionAttempts[id] != resumeAttempt
                || (task.kind == .http && httpResumeAttempts[id] != resumeAttempt) {
                scheduling.userPause(model.tasks[index])
                model.tasks[index].status = .paused
                return
            }
            scheduling.userResume(model.tasks[index])
            scheduling.queue(model.tasks[index])
            model.tasks[index].status = .queued
            model.tasks[index].errorMessage = nil
            model.tasks[index].httpValidationError = nil
            await refreshScheduling(sample: false)
        } catch {
            guard generation == token, resubmissionAttempts[id] == resumeAttempt, !model.userPausedTaskIDs.contains(id),
                  task.kind != .http || httpResumeAttempts[id] == resumeAttempt else { return }
            let reason = EngineStatusPresentation.errorMessage(error)
            resubmissionFailed(String(localized: "未能恢复下载：\(reason)。任务仍处于暂停状态，请检查原始链接和保存目录后重试。"), id: id)
        }
    }

    private func resubmissionFailed(_ message: String, id: DownloadTask.ID) {
        guard let index = model.tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        model.tasks[index].status = .paused
        model.tasks[index].errorMessage = message
    }

    private func failWaitingVideos(reason: String) {
        for index in model.tasks.indices where waitingVideoLinks[model.tasks[index].id] != nil {
            model.tasks[index].status = .failed
            model.tasks[index].errorMessage = reason
        }
        waitingVideoLinks.removeAll()
    }

    private func submitWaitingVideos() async {
        await videoConfigurationTask?.value
        guard let token = generation, !Task.isCancelled, let engine = engine(for: .video) else { return }
        for id in model.tasks.map(\.id) {
            guard generation == token, !Task.isCancelled else { return }
            guard let pending = waitingVideoLinks[id], !submittingVideoIDs.contains(id),
                  model.tasks.contains(where: { $0.id == id && $0.status == .queued && $0.pauseReason == nil }),
                  !scheduleRequiresPause() else { continue }
            submittingVideoIDs.insert(id)
            pendingAdds[.video, default: 0] += 1
            defer {
                submittingVideoIDs.remove(id)
                pendingAdds[.video, default: 0] -= 1
                revisions[.video, default: 0] += 1
            }
            do {
                let queued = shouldQueueNewTask()
                let engineID: String
                if let video = engine as? YtDlpEngine {
                    engineID = try await video.add(
                        link: pending.link, directory: pending.directory, entry: pending.entry, paused: queued,
                        formatID: pending.formatID, formatVideoOnly: pending.videoOnly,
                        outputOptions: model.tasks.first(where: { $0.id == id })?.videoOptions
                    )
                } else {
                    engineID = try await queued
                        ? engine.addQueued(link: pending.link, directory: pending.directory)
                        : engine.add(link: pending.link, directory: pending.directory)
                }
                guard generation == token, let index = model.tasks.firstIndex(where: { $0.id == id }) else {
                    excludedTaskIDs[.video, default: []].insert(engineID)
                    try await engine.remove(engineID, deleteFiles: false)
                    continue
                }
                model.tasks[index].engineTaskID = engineID
                if queued { scheduling.queue(model.tasks[index]) }
                waitingVideoLinks[id] = nil
                if model.tasks[index].status == .paused {
                    try await engine.pause(engineID)
                }
            } catch {
                waitingVideoLinks[id] = nil
                guard generation == token, let index = model.tasks.firstIndex(where: { $0.id == id }) else { continue }
                model.tasks[index].status = .failed
                model.tasks[index].errorMessage = EngineStatusPresentation.errorMessage(error)
            }
        }
    }

    private func scheduleRequiresPause() -> Bool {
        guard let settings = model.downloadSettings else { return false }
        let configuration = TransferScheduleController.Configuration(settings: settings)
        return configuration.enabled && configuration.isValid && !configuration.isActive(at: .now, calendar: .current)
    }

    private func shouldQueueNewTask() -> Bool {
        let occupied = model.activeTasks.filter {
            scheduling.occupiesSlot($0) && !scheduling.isQueuePaused($0)
        }.count
        return occupied >= max(1, latestOptions?.maxConcurrentDownloads ?? 1)
    }

    func setTaskLimits(_ id: DownloadTask.ID, download: Int64?, upload: Int64?) {
        guard let index = model.tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }),
              [.http, .bittorrent].contains(model.tasks[index].kind) else { return }
        model.tasks[index].downloadLimit = download.flatMap { $0 > 0 ? min($0, Int64(Int32.max)) : nil }
        model.tasks[index].uploadLimit = model.tasks[index].kind == .bittorrent
            ? upload.flatMap { $0 > 0 ? min($0, Int64(Int32.max)) : nil } : nil
        Task { await refreshScheduling(sample: false) }
    }

    func setPriority(_ id: DownloadTask.ID, priority: DownloadTask.Priority) {
        guard let index = model.tasks.firstIndex(where: { $0.id == id && $0.deletedAt == nil }) else { return }
        model.tasks[index].priority = priority
    }

    func moveInQueue(_ id: DownloadTask.ID, toFront: Bool) {
        model.tasks = GlobalConcurrencyPolicy.moving(tasks: model.tasks, id: id, toFront: toFront)
    }

    private func refreshScheduling(sample: Bool = true) async {
        guard let token = generation, let latestOptions else { return }
        await scheduling.refresh(
            model: model, engines: engines.filter { started.contains($0.kind) },
            options: latestOptions, sample: sample,
            isCurrent: { self.generation == token && !Task.isCancelled }
        )
    }

    private func setError(_ message: String, for id: DownloadTask.ID) {
        guard let index = model.tasks.firstIndex(where: { $0.id == id }) else { return }
        model.tasks[index].errorMessage = message
    }

    private func engine(for kind: TaskKind) -> (any DownloadEngine)? {
        guard started.contains(kind) else { return nil }
        return engines.first { $0.kind == kind }
    }

    private func stopEngines() async {
        await withTaskGroup(of: Void.self) { group in
            for engine in engines {
                group.addTask { await engine.stop() }
            }
        }
    }
}

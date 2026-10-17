import Darwin
import Foundation
import OSLog

/// 每个视频一个 yt-dlp 子进程；仅在任务状态变化时持久化。
public actor YtDlpEngine: DownloadEngine {
    public nonisolated let kind: TaskKind = .video
    public typealias Updater = @Sendable () async throws -> URL
    public typealias CookieProvider = @Sendable (VideoSite) async throws -> [VideoCookie]

    private let stateDirectory: URL
    private var binaryURL: URL?
    private let installer: ManagedToolInstaller?
    private let ffmpegURL: URL?
    private let denoURL: URL?
    private let allowHomebrewFallback: Bool
    private var channel: YtDlpChannel
    private var updatesEnabled: Bool
    private let updater: Updater?
    private var quality: YtDlpQuality
    private var cookiesURL: URL?
    private var cookieProvider: CookieProvider?
    private var outputOptions = YtDlpOutputOptions()
    private var subtitles: YtDlpSubtitles
    private var options: EngineOptions?
    private var resolvedBinary: URL?
    private var jobs: [YtDlpJob] = []
    private var progress: [String: YtDlpProgress] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var tokens: [String: UUID] = [:]
    private var children: [String: YtDlpProcess] = [:]
    private var starting: Task<Void, any Error>?
    private var stopping: Task<Void, Never>?
    private var persistenceError: String?
    private var schedulingSuspensions = 0
    private static let logger = Logger(subsystem: "MuleeCore", category: "YtDlp")

    /// 显式路径优先，随后使用 installer；Homebrew 回退需开发环境显式开启。
    /// ffmpeg 只接受路径注入；YouTube 的 Deno 可注入或由 installer 安装。
    public init(
        stateDirectory: URL,
        binaryURL: URL? = nil,
        installer: ManagedToolInstaller? = ManagedToolInstaller(),
        ffmpegURL: URL? = nil,
        denoURL: URL? = nil,
        quality: YtDlpQuality = .compatible,
        channel: YtDlpChannel = .stable,
        cookiesURL: URL? = nil,
        subtitles: YtDlpSubtitles = YtDlpSubtitles(),
        allowHomebrewFallback: Bool = false,
        updatesEnabled: Bool = true,
        updater: Updater? = nil
    ) {
        self.stateDirectory = stateDirectory
        self.binaryURL = binaryURL
        self.installer = installer
        self.ffmpegURL = ffmpegURL
        self.denoURL = denoURL
        self.quality = quality
        self.channel = channel
        self.cookiesURL = cookiesURL
        self.subtitles = subtitles
        self.allowHomebrewFallback = allowHomebrewFallback
        self.updatesEnabled = updatesEnabled
        self.updater = updater
    }

    /// 作用于之后启动（含恢复）的任务，不中断当前下载。
    public func configure(quality: YtDlpQuality, cookiesURL: URL?, subtitles: YtDlpSubtitles = YtDlpSubtitles()) {
        self.quality = quality
        self.cookiesURL = cookiesURL
        self.subtitles = subtitles
    }

    /// 通道切换只替换后续任务使用的工具，不中断正在运行的子进程。
    public func configure(
        quality: YtDlpQuality, cookiesURL: URL?, subtitles: YtDlpSubtitles,
        channel: YtDlpChannel, updatesEnabled: Bool
    ) async throws {
        if channel != self.channel {
            let binary = try await resolveBinary(channel: channel, useExplicitPath: false)
            binaryURL = binary
            if options != nil { resolvedBinary = binary }
        }
        self.channel = channel
        self.updatesEnabled = updatesEnabled
        configure(quality: quality, cookiesURL: cookiesURL, subtitles: subtitles)
    }

    public func configureOutput(_ options: YtDlpOutputOptions) {
        outputOptions = options
    }

    public func configureCookies(provider: CookieProvider?) {
        cookieProvider = provider
    }

    public func start(options: EngineOptions) async throws {
        if let stopping { await stopping.value }
        if let starting { return try await starting.value }
        if self.options != nil { return }
        try Self.validate(options)
        let task = Task { try await launch(options) }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    public func stop() async {
        if let stopping { return await stopping.value }
        guard options != nil || starting != nil else { return }
        let task = Task {
            if let starting {
                do { try await starting.value } catch {
                    Self.logger.error("停止前启动失败：\(error.localizedDescription, privacy: .public)")
                }
            }
            guard options != nil else { return }
            for id in workers.keys { captureProgress(id) }
            options = nil
            await cancelWorkers(Array(workers.keys))
            persistOrReport()
        }
        stopping = task
        await task.value
        stopping = nil
    }

    public func apply(options: EngineOptions) async throws {
        try requireRunning()
        try Self.validate(options)
        try FileManager.default.createDirectory(at: options.downloadDirectory, withIntermediateDirectories: true)
        let previousConcurrency = self.options?.maxConcurrentDownloads ?? options.maxConcurrentDownloads
        let concurrencyChanged = previousConcurrency != options.maxConcurrentDownloads
        let cacheChanged = self.options?.diskCacheMegabytes != options.diskCacheMegabytes
        let restart = self.options?.downloadLimit != options.downloadLimit
            || (cacheChanged && self.options.map(Self.downloadBufferBytes) != Self.downloadBufferBytes(options))
            || (concurrencyChanged && options.downloadLimit > 0)
        self.options = options
        // Rate and buffer options are startup-only; requeue workers with their existing .part files.
        // The coordinator reserves that envelope while video workers are running.
        // 无限速时只调整名额，不能因派生缓冲大小变化中断下载或后处理。
        // 有限速时仍沿用重启分配额度的既有路径，本次不改变该行为。
        if restart {
            await requeueActive()
        } else if options.maxConcurrentDownloads < previousConcurrency {
            await requeueOverflow()
        }
        try persist()
        schedule()
    }

    public func add(link: ParsedLink, directory: URL? = nil) async throws -> String {
        try await add(link: link, directory: directory, entry: nil, paused: false)
    }

    public func addQueued(link: ParsedLink, directory: URL?) async throws -> String {
        try await add(link: link, directory: directory, entry: nil, paused: true)
    }

    public func add(link: ParsedLink, directory: URL?, entry: YtDlpPlaylistEntry?, paused: Bool = false,
                    formatID: String? = nil, formatVideoOnly: Bool = false,
                    outputOptions: YtDlpTaskOptions? = nil) async throws -> String {
        try requireRunning()
        try outputOptions?.validate()
        if let formatID, !YtDlpFormat.isValidID(formatID) { throw EngineError.unsupportedLink }
        guard case .video(let url, let site, _) = link,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { throw EngineError.unsupportedLink }
        guard let options else { throw EngineError.notRunning }
        let destination = directory ?? options.downloadDirectory
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let id = UUID().uuidString.lowercased()
        jobs.append(YtDlpJob(id: id, url: url, site: site, directory: destination, name: entry?.taskTitle ?? url.lastPathComponent,
                                playlistIndex: entry?.index, playlistTitle: entry?.title, playlistFilenamePrefix: entry?.filenamePrefix,
                                formatID: formatID, outputOptions: outputOptions, formatVideoOnly: formatVideoOnly, status: paused ? .paused : .queued))
        try persist()
        if !paused, options.downloadLimit > 0 { await requeueActive() }
        schedule()
        return id
    }

    public func pause(_ engineTaskID: String) async throws {
        try requireRunning()
        let index = try index(engineTaskID)
        guard jobs[index].status != .completed else { return }
        captureProgress(engineTaskID)
        jobs[index].status = .paused
        try persist()
        await cancelWorkers([engineTaskID])
        if options?.downloadLimit ?? 0 > 0 { await requeueActive() }
        schedule()
    }

    public func resume(_ engineTaskID: String) async throws {
        try requireRunning()
        let index = try index(engineTaskID)
        guard [.paused, .failed].contains(jobs[index].status) else { return }
        jobs[index].status = .queued
        jobs[index].errorMessage = nil
        jobs[index].retried = false
        try persist()
        if options?.downloadLimit ?? 0 > 0 { await requeueActive() }
        schedule()
    }

    public func remove(_ engineTaskID: String, deleteFiles: Bool) async throws {
        try requireRunning()
        let index = try index(engineTaskID)
        jobs[index].status = .paused
        try persist()
        await cancelWorkers([engineTaskID])
        let current = try self.index(engineTaskID)
        if deleteFiles { try YtDlpFileSafety.trash(jobs[current]) }
        jobs.remove(at: current)
        progress[engineTaskID] = nil
        try persist()
        if options?.downloadLimit ?? 0 > 0 { await requeueActive() }
        schedule()
    }

    public func snapshots() async throws -> [EngineTaskSnapshot] {
        try requireRunning()
        if let persistenceError { throw EngineError.invalidResponse(persistenceError) }
        return jobs.map { $0.snapshot(progress: progress[$0.id]) }
    }

    private func launch(_ options: EngineOptions) async throws {
        let binary = try await resolveBinary()
        try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: options.downloadDirectory, withIntermediateDirectories: true)
        let file = stateDirectory.appendingPathComponent("jobs.json")
        if FileManager.default.fileExists(atPath: file.path) {
            jobs = try JSONDecoder().decode([YtDlpJob].self, from: Data(contentsOf: file))
            guard Set(jobs.map(\.id)).count == jobs.count,
                  jobs.allSatisfy({ UUID(uuidString: $0.id) != nil }) else {
                throw EngineError.invalidResponse(String(localized: "视频任务记录无效", bundle: .module))
            }
        }
        for index in jobs.indices where [.downloading, .postProcessing, .queued].contains(jobs[index].status) {
            jobs[index].status = .queued
        }
        resolvedBinary = binary
        self.options = options
        progress.removeAll()
        schedule()
    }

    private func resolveBinary(channel selectedChannel: YtDlpChannel? = nil, useExplicitPath: Bool = true) async throws -> URL {
        if useExplicitPath, let binaryURL {
            guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else { throw EngineError.binaryNotFound }
            return binaryURL
        }
        let tool = ManagedTool.ytDlp(channel: selectedChannel ?? channel)
        if let installer, let installed = try await installer.installedURL(for: tool) { return installed }
        if !useExplicitPath, let installer { return try await installer.install(tool) }
        if allowHomebrewFallback, let url = Self.homebrew("yt-dlp") { return url }
        if let installer { return try await installer.install(tool) }
        throw EngineError.binaryNotFound
    }

    private static func homebrew(_ name: String) -> URL? {
        let url = URL(fileURLWithPath: "/opt/homebrew/bin/" + name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    private func schedule() {
        guard stopping == nil, schedulingSuspensions == 0, let options else { return }
        for job in jobs where job.status == .queued && workers[job.id] == nil {
            guard workers.count < options.maxConcurrentDownloads else { break }
            let token = UUID()
            tokens[job.id] = token
            workers[job.id] = Task { await run(job.id, token: token) }
        }
    }

    private func run(_ id: String, token: UUID) async {
        let selectedQuality: YtDlpQuality = jobs.first(where: { $0.id == id })?.formatID == nil ? quality : .best
        let selectedOutput = outputOptions
        let selectedSubtitles = subtitles
        let selectedChannel = channel
        let shouldUpdate = updatesEnabled
        var cookieFile: YtDlpCookieFile?
        defer { try? cookieFile?.remove() }
        do {
            guard let index = jobs.firstIndex(where: { $0.id == id }), tokens[id] == token else { return }
            jobs[index].status = .downloading
            progress[id] = YtDlpProgress()
            try persist()
            var deno = denoURL
            if jobs[index].site == .youtube, deno == nil {
                if let installer {
                    do { deno = try await installer.install(.deno) } catch {
                        guard allowHomebrewFallback, let fallback = Self.homebrew("deno") else { throw error }
                        deno = fallback
                    }
                } else if allowHomebrewFallback { deno = Self.homebrew("deno") }
            }
            try Task.checkCancellation()
            guard tokens[id] == token, let current = jobs.first(where: { $0.id == id }),
                  let binary = resolvedBinary else { return }
            try current.outputOptions?.validate()
            let cookies = try await cookieProvider?(current.site) ?? []
            try Task.checkCancellation()
            guard tokens[id] == token else { return }
            var includeThumbnail = true
            while true {
                if !cookies.isEmpty { cookieFile = try YtDlpCookieFile(cookies: cookies, site: current.site) }
                let child = try YtDlpProcess(
                    binary: binary, arguments: arguments(
                        for: current, deno: deno, quality: selectedQuality, subtitles: selectedSubtitles,
                        output: selectedOutput, includeThumbnail: includeThumbnail, taskCookiesURL: cookieFile?.url
                    ), cleanupURL: cookieFile?.url
                )
                children[id] = child
                var pending = Data()
                var errors = ""
                for await chunk in child.output {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 10) {
                        let line = String(decoding: pending[..<newline], as: UTF8.self)
                        pending.removeSubrange(...newline)
                        consume(line, id: id, token: token, errors: &errors)
                    }
                }
                if !pending.isEmpty { consume(String(decoding: pending, as: UTF8.self), id: id, token: token, errors: &errors) }
                await child.finish()
                guard tokens[id] == token else { return }
                children[id] = nil
                if child.status == 0 { break }
                if includeThumbnail, selectedOutput.embedMetadata, YtDlpFinalName.isThumbnailFailure(errors) {
                    includeThumbnail = false
                    continue
                }
                let raw = cookieFile != nil ? String(localized: "使用登录状态下载失败，请重新传递登录状态后重试", bundle: .module)
                    : (errors.isEmpty ? String(localized: "yt-dlp 退出码 \(child.status)", bundle: .module) : errors)
                if try await retry(id, token: token, raw: raw, channel: selectedChannel, updatesEnabled: shouldUpdate) { return }
                throw EngineError.launchFailed(raw)
            }
            guard let index = jobs.firstIndex(where: { $0.id == id }),
                  let path = progress[id]?.finalPath else {
                throw EngineError.invalidResponse(String(localized: "yt-dlp 未返回最终文件路径", bundle: .module))
            }
            let url = try YtDlpFinalName.resolve(
                URL(fileURLWithPath: path), audioFormat: current.outputOptions?.audioOnly == true ? selectedOutput.audioFormat : nil
            )
            guard YtDlpFileSafety.belongs(url, to: jobs[index]), FileManager.default.fileExists(atPath: url.path) else {
                throw EngineError.invalidResponse(String(localized: "yt-dlp 返回的文件不属于此任务", bundle: .module))
            }
            if current.outputOptions?.audioOnly != true {
                try await normalizeHEVC(
                    url, job: jobs[index], token: token, quality: selectedQuality,
                    codec: progress[id]?.videoCodec
                )
            }
            guard tokens[id] == token, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            if jobs[index].site == .bilibili, selectedSubtitles.danmaku, current.outputOptions?.audioOnly != true {
                try await convertDanmaku(url, job: jobs[index], token: token, videoSize: progress[id]?.videoSize)
            }
            guard tokens[id] == token, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            // 同时传 --write-subs 与 --embed-subs 时 yt-dlp 会保留源字幕；成功后只清理本任务的副本。
            do {
                try YtDlpFileSafety.removeEmbeddedSubtitles(
                    for: jobs[index], video: url,
                    languages: current.outputOptions?.subtitleLanguages ?? selectedOutput.subtitleLanguages,
                    mode: selectedOutput.subtitleMode
                )
            } catch {
                Self.logger.error("清理已嵌入字幕失败：\(error.localizedDescription, privacy: .public)")
            }
            captureProgress(id)
            var finalURL = url
            do {
                let renamed = try YtDlpFinalName.finalize(url, jobID: id)
                finalURL = renamed.file
                jobs[index].finalFiles = renamed.names
            } catch {
                Self.logger.error("去掉文件名前缀失败，保留原文件名：\(error.localizedDescription, privacy: .public)")
            }
            jobs[index].savePath = finalURL
            jobs[index].status = .completed
            jobs[index].errorMessage = nil
            let size = try finalURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
            jobs[index].totalBytes = size.map(Int64.init)
            jobs[index].receivedBytes = jobs[index].totalBytes ?? jobs[index].receivedBytes
            progress[id] = nil
            try persist()
        } catch {
            guard tokens[id] == token else { return }
            if let child = children.removeValue(forKey: id) { await child.terminate() }
            guard tokens[id] == token, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
            captureProgress(id)
            jobs[index].status = .failed
            let raw: String
            if case EngineError.launchFailed(let text) = error { raw = text }
            else { raw = String(describing: error) }
            jobs[index].errorMessage = YtDlpErrorDescriptions.message(raw)
            jobs[index].isFileWriteFailure = EngineTaskSnapshot.describesFileWriteFailure(raw)
            progress[id] = nil
            persistOrReport()
        }
        guard tokens[id] == token else { return }
        workers[id] = nil
        tokens[id] = nil
        if options?.downloadLimit ?? 0 > 0 { await requeueActive() }
        schedule()
    }

    private func retry(
        _ id: String, token: UUID, raw: String, channel: YtDlpChannel, updatesEnabled: Bool
    ) async throws -> Bool {
        guard updatesEnabled,
              let index = jobs.firstIndex(where: { $0.id == id }), !jobs[index].retried,
              updater != nil || installer != nil else { return false }
        jobs[index].retried = true
        try persist()
        do {
            let updated: URL?
            if let updater { updated = try await updater() }
            else if let installer { updated = try await installer.install(.ytDlp(channel: channel), force: true) }
            else { updated = nil }
            if self.channel == channel, let updated {
                binaryURL = updated
                resolvedBinary = updated
            }
        } catch {
            throw EngineError.launchFailed(String(localized: "\(raw)\n更新 yt-dlp 失败：\(String(describing: error))", bundle: .module))
        }
        try Task.checkCancellation()
        guard tokens[id] == token, let current = jobs.firstIndex(where: { $0.id == id }) else { return false }
        jobs[current].status = .queued
        workers[id] = nil
        tokens[id] = nil
        try persist()
        schedule()
        return true
    }

    private func consume(_ line: String, id: String, token: UUID, errors: inout String) {
        guard tokens[id] == token, let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        if progress[id]?.consume(line) == true {
            // 分 P / 剧集任务保留列表接口给的标题，yt-dlp 的标题只用于单个视频。
            if let title = progress[id]?.title, jobs[index].playlistTitle?.isEmpty ?? true {
                if jobs[index].name != title {
                    jobs[index].name = title
                    persistOrReport()
                }
            }
            if progress[id]?.postProcessing == true, jobs[index].status != .postProcessing {
                captureProgress(id)
                jobs[index].status = .postProcessing
                persistOrReport()
            }
        } else if !line.isEmpty {
            errors = String((errors + "\n" + line).suffix(16_384))
        }
    }

    /// Share the requested budget among workers, with a 16 MiB per-worker ceiling.
    /// yt-dlp requires a positive buffer; 0 uses its minimum 1 KiB read block.
    /// This bounds HTTP read blocks, not ffmpeg or fragment-assembly memory.
    static func downloadBufferBytes(_ options: EngineOptions) -> Int {
        let bytes = min(512, max(0, options.diskCacheMegabytes)) * 1_048_576
        let workers = max(1, options.maxConcurrentDownloads)
        let buffer = max(1024, min(16 * 1_048_576, bytes / workers))
        // Keep progress/pause responsive under throttling: at most one second of download data.
        if options.downloadLimit > 0 {
            return Int(min(Int64(buffer), max(1024, options.downloadLimit / Int64(workers))))
        }
        return buffer
    }

    private func arguments(
        for job: YtDlpJob, deno: URL?, quality: YtDlpQuality, subtitles: YtDlpSubtitles,
        output: YtDlpOutputOptions, includeThumbnail: Bool, taskCookiesURL: URL?
    ) -> [String] {
        var result = [
            "--ignore-config", "--no-simulate", "--newline", "--progress",
            "--no-colors", "--continue", "--no-overwrites", "--no-cache-dir",
            "--paths", job.directory.path,
            "--output", job.id + "-" + (job.playlistFilenamePrefix ?? job.playlistIndex.map { index in
                job.site == .youtube ? (index < 10 ? "0" : "") + String(index) + " - " : "P\(index) "
            } ?? "") + output.filenamePreset.template,
            "--print", YtDlpProgress.metadataTemplate,
            "--print", YtDlpProgress.fileTemplate,
            "--progress-template", YtDlpProgress.downloadTemplate,
            "--progress-template", YtDlpProgress.postprocessTemplate
        ] + YtDlpPlaylistEntry.arguments(for: job.url, site: job.site) + output.arguments(
            quality: quality, site: job.site, task: job.outputOptions ?? .init(),
            formatID: job.formatID, formatVideoOnly: job.formatVideoOnly == true,
            bilibiliSubtitles: subtitles, includeThumbnail: includeThumbnail
        )
        result += HTTPProxyConfiguration.current().proxyArguments()
        if let ffmpegURL { result += ["--ffmpeg-location", ffmpegURL.path] }
        if let deno { result += ["--js-runtimes", "deno:" + deno.path] }
        if let url = taskCookiesURL ?? cookiesURL { result += ["--cookies", url.path] }
        if let options {
            // HttpFD reads this many bytes then writes; disable automatic growth to keep it bounded.
            result += ["--buffer-size", String(Self.downloadBufferBytes(options)), "--no-resize-buffer"]
        }
        if let options, options.downloadLimit > 0 {
            result += ["--limit-rate", String(max(1, options.downloadLimit / Int64(max(1, workers.count))))]
        }
        return result + ["--", job.url.absoluteString]
    }

    private func normalizeHEVC(
        _ file: URL, job: YtDlpJob, token: UUID, quality: YtDlpQuality, codec: String?
    ) async throws {
        guard quality == .compatible, let codec,
              ["hev1", "hvc1", "hevc"].contains(where: codec.lowercased().hasPrefix) else { return }
        guard let ffmpegURL else { throw EngineError.launchFailed("ffmpeg is required for HEVC compatibility") }
        guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { throw CancellationError() }
        if jobs[index].status != .postProcessing {
            jobs[index].status = .postProcessing
            try persist()
        }
        // QuickTime 要求 HEVC 的 hvc1 标签；只重封装，不重新编码。
        let temporary = job.directory.appendingPathComponent(job.id + "-compatible-" + UUID().uuidString + ".mp4")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let child = try YtDlpProcess(binary: ffmpegURL, arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", file.path,
            "-map", "0", "-c", "copy", "-tag:v", "hvc1", temporary.path
        ])
        children[job.id] = child
        var output = Data()
        for await chunk in child.output {
            output.append(chunk)
            if output.count > 16_384 { output = Data(output.suffix(16_384)) }
        }
        await child.finish()
        guard tokens[job.id] == token else { throw CancellationError() }
        children[job.id] = nil
        guard child.status == 0 else {
            throw EngineError.launchFailed("ffmpeg：" + String(decoding: output, as: UTF8.self))
        }
        guard rename(temporary.path, file.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    private func convertDanmaku(_ video: URL, job: YtDlpJob, token: UUID, videoSize: CGSize?) async throws {
        let base = video.deletingPathExtension()
        let xml = base.appendingPathExtension("danmaku.xml")
        guard FileManager.default.fileExists(atPath: xml.path) else { return }
        do {
            let values = try xml.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard YtDlpFileSafety.belongs(xml, to: job), values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw EngineError.invalidResponse(String(localized: "弹幕 XML 不属于此任务", bundle: .module))
            }
            guard let index = jobs.firstIndex(where: { $0.id == job.id }) else { throw CancellationError() }
            jobs[index].status = .postProcessing
            try persist()
            let result = try await DanmakuConverter().convertInBackground(
                xml: xml, to: base.appendingPathExtension("danmaku.ass"), videoSize: videoSize
            )
            try Task.checkCancellation()
            guard tokens[job.id] == token else { throw CancellationError() }
            try FileManager.default.removeItem(at: xml)
            Self.logger.info("弹幕 ASS 转换完成：总数 \(result.total)，写入 \(result.written)，丢弃 \(result.dropped)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("弹幕 ASS 转换失败，保留 XML：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func captureProgress(_ id: String) {
        guard let value = progress[id], let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].totalBytes = value.totalBytes
        jobs[index].receivedBytes = value.receivedBytes
    }

    private func cancelWorkers(_ ids: [String]) async {
        schedulingSuspensions += 1
        defer { schedulingSuspensions -= 1 }
        var tasks: [Task<Void, Never>] = []
        var processes: [YtDlpProcess] = []
        for id in ids {
            tokens[id] = nil
            if let task = workers.removeValue(forKey: id) {
                task.cancel()
                tasks.append(task)
            }
            if let child = children.removeValue(forKey: id) { processes.append(child) }
        }
        for child in processes { await child.terminate() }
        for task in tasks { await task.value }
    }

    private func requeueOverflow() async {
        guard let options else { return }
        let excess = max(0, workers.count - options.maxConcurrentDownloads)
        let candidates = jobs.reversed().filter {
            workers[$0.id] != nil && [.queued, .downloading].contains($0.status)
        }
        // 尚未启动子进程的先退回队列；已经后处理的任务保留到完成，即使暂时超限。
        let pending = candidates.filter { children[$0.id] == nil }
        let active = candidates.filter { children[$0.id] != nil }
        let ids = (pending + active).prefix(excess).map(\.id)
        for id in ids {
            captureProgress(id)
            if let index = jobs.firstIndex(where: { $0.id == id }) { jobs[index].status = .queued }
        }
        await cancelWorkers(ids)
    }

    private func requeueActive() async {
        let ids = Array(workers.keys)
        for id in ids {
            captureProgress(id)
            if let index = jobs.firstIndex(where: { $0.id == id }), [.downloading, .postProcessing].contains(jobs[index].status) {
                jobs[index].status = .queued
            }
        }
        await cancelWorkers(ids)
    }

    private func persist() throws {
        try JSONEncoder().encode(jobs).write(to: stateDirectory.appendingPathComponent("jobs.json"), options: .atomic)
        persistenceError = nil
    }

    private func persistOrReport() {
        do { try persist() } catch {
            persistenceError = String(localized: "无法保存视频任务：\(error.localizedDescription)", bundle: .module)
            Self.logger.error("无法保存视频任务：\(error.localizedDescription, privacy: .public)")
        }
    }

    private func requireRunning() throws {
        guard options != nil, stopping == nil else { throw EngineError.notRunning }
    }

    private func index(_ id: String) throws -> Int {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else {
            throw EngineError.invalidResponse(String(localized: "找不到视频任务：\(id)", bundle: .module))
        }
        return index
    }

    private static func validate(_ options: EngineOptions) throws {
        guard options.maxConcurrentDownloads > 0, options.downloadLimit >= 0 else {
            throw EngineError.invalidResponse(String(localized: "并发数必须大于零，限速不能为负数", bundle: .module))
        }
    }
}

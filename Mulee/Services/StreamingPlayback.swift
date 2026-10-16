import AppKit
import MuleeCore
import Observation

/// 播放器和缓冲状态共用一个入口，切换详情不会中断用户发起的缓冲。
@MainActor @Observable
final class StreamingPlayback {
    static let shared = StreamingPlayback()
    static let videoExtensions: Set<String> = ["mp4", "mkv", "mov", "m4v", "webm", "avi", "ts", "flv"]
    static let playerBundleIDs = ["com.colliderli.iina", "org.videolan.vlc"]

    private(set) var buffering: [UUID: Double] = [:]
    private(set) var playing: Set<UUID> = []
    private(set) var issues: [UUID: String] = [:]
    @ObservationIgnored private var jobs: [UUID: Task<Void, Never>] = [:]

    static func isVideo(_ name: String) -> Bool {
        videoExtensions.contains(URL(filePath: name).pathExtension.lowercased())
    }

    static func canPlay(_ task: DownloadTask, files: [TorrentFileEntry] = []) -> Bool {
        guard task.deletedAt == nil, task.fileMissing != true else { return false }
        if task.kind == .bittorrent {
            return task.engineTaskID != nil && [.downloading, .queued, .paused, .seeding, .completed].contains(task.status)
                && (isVideo(task.name) || files.contains { isVideo($0.path) })
        }
        return [.completed, .seeding].contains(task.status) && task.savePath.map {
            isVideo($0.lastPathComponent) && !IncompleteHTTPTransfer.isStagingFile($0)
        } == true
    }

    static func bufferThreshold(size: Int64) -> Int64 {
        guard size > 0 else { return 0 }
        return min(20_000_000, size / 20 + (size % 20 == 0 ? 0 : 1))
    }

    static func preferredPlayer(installed: Set<String>) -> String? {
        playerBundleIDs.first { installed.contains($0) }
    }

    static func fileURL(task: DownloadTask, file: TorrentFileEntry) -> URL? {
        let path = file.storagePath ?? file.path
        if path.hasPrefix("/") { return URL(filePath: path) }
        if let root = task.writeDirectories?.first { return root.appendingPathComponent(path) }
        guard let content = task.savePath else { return nil }
        return content.deletingLastPathComponent().appendingPathComponent(path)
    }

    func play(
        task: DownloadTask, engine: TorrentEngine?, file: TorrentFileEntry? = nil,
        coordinator: DownloadCoordinator? = nil
    ) {
        guard task.deletedAt == nil, task.fileMissing != true,
              Self.canPlay(task, files: file.map { [$0] } ?? [])
                || task.kind == .bittorrent && task.engineTaskID != nil
                    && [.downloading, .queued, .paused, .seeding, .completed].contains(task.status),
              jobs[task.id] == nil else { return }
        issues[task.id] = nil
        jobs[task.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                self.jobs[task.id] = nil
                self.buffering[task.id] = nil
                self.playing.remove(task.id)
            }
            var streamingIndex: Int?
            do {
                if task.kind == .bittorrent {
                    guard let engine, let id = task.engineTaskID else { return }
                    let files = try await engine.files(id)
                    guard let selected = file.flatMap({ requested in files.first { $0.index == requested.index } })
                        ?? files.first(where: { Self.isVideo($0.path) && $0.priority > 0 }),
                          Self.isVideo(selected.path) else { return }
                    if selected.done >= selected.size {
                        if let url = Self.fileURL(task: task, file: selected) {
                            try await self.open(url, logicalName: selected.path)
                        }
                        return
                    }
                    if task.status == .paused { await coordinator?.resume(task.id) }
                    try Task.checkCancellation()
                    streamingIndex = selected.index
                    self.buffering[task.id] = 0
                    try await engine.setStreaming(id, fileIndex: selected.index, enabled: true)
                    var opened = false
                    while !Task.isCancelled {
                        guard let current = try await engine.files(id).first(where: { $0.index == selected.index }) else { break }
                        let threshold = Self.bufferThreshold(size: current.size)
                        let contiguous = current.contiguousDone ?? 0
                        if !opened {
                            self.buffering[task.id] = threshold > 0 ? min(1, Double(contiguous) / Double(threshold)) : 0
                            if threshold > 0 && contiguous >= threshold, let url = Self.fileURL(task: task, file: current) {
                                try Task.checkCancellation()
                                try await self.open(url, logicalName: current.path)
                                opened = true
                                self.buffering[task.id] = nil
                                self.playing.insert(task.id)
                            }
                        }
                        if try await engine.taskInfo(id).isFinished { break }
                        try await Task.sleep(for: .seconds(1))
                    }
                } else if let url = task.savePath {
                    try await self.open(url, logicalName: url.lastPathComponent)
                }
            } catch is CancellationError {
                // 用户取消只撤销缓冲和顺序模式，不关闭已打开的播放器。
            } catch {
                self.issues[task.id] = String(localized: "暂时无法播放，请确认文件可用且已安装播放器。")
            }
            if let index = streamingIndex, let id = task.engineTaskID, let engine {
                // 已取消的任务不能承担 RPC 清理：独立任务确保取消后仍撤销持久化的模式。
                do { try await Task { try await engine.setStreaming(id, fileIndex: index, enabled: false) }.value }
                catch { self.issues[task.id] = String(localized: "无法关闭顺序下载，请在任务详情中关闭后重试。") }
            }
        }
    }

    func cancel(_ id: UUID) {
        guard let job = jobs[id] else { return }
        job.cancel()
        buffering[id] = nil
    }

    func stop() async {
        let running = Array(jobs.values)
        for id in jobs.keys { cancel(id) }
        for job in running { await job.value }
    }

    private func open(_ url: URL, logicalName: String) async throws {
        let workspace = NSWorkspace.shared
        let installed = Set(Self.playerBundleIDs.filter { workspace.urlForApplication(withBundleIdentifier: $0) != nil })
        let application = Self.preferredPlayer(installed: installed).flatMap {
            workspace.urlForApplication(withBundleIdentifier: $0)
        } ?? workspace.urlForApplication(toOpen: url.deletingLastPathComponent().appendingPathComponent(URL(filePath: logicalName).lastPathComponent))
        if let application {
            _ = try await workspace.open([url], withApplicationAt: application, configuration: .init())
        } else if !workspace.open(url) {
            throw CocoaError(.fileReadUnknown)
        }
    }
}

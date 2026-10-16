import Foundation
import MuleeCore
import Observation

/// 仅在详情栏显示该 BT 任务期间轮询，切换任务即取消。
@Observable
final class BitTorrentFilesModel {
    private(set) var files: [TorrentFileEntry] = []
    private(set) var info: TorrentTaskInfo?
    private(set) var diagnostics: TorrentDiagnostics?
    private(set) var isUpdating = false
    var issue: String?
    private var revision = 0
    private var currentID: String?
    private var engine: TorrentEngine?
    private var generation = 0
    #if DEBUG
    private var isPreview = false
    #endif

    var selectedCount: Int { files.filter { $0.priority > 0 }.count }

    func watch(engine: TorrentEngine?, id: String?) async {
        #if DEBUG
        if isPreview { return }
        #endif
        generation += 1
        let watchGeneration = generation
        revision += 1
        currentID = id
        self.engine = engine
        files = []
        info = nil
        diagnostics = nil
        issue = nil
        isUpdating = false
        guard let engine, let id else { return }
        while !Task.isCancelled {
            let currentRevision = revision
            do {
                let entries = try await engine.files(id)
                let details = try await engine.taskInfo(id)
                guard !Task.isCancelled, generation == watchGeneration else { return }
                if !isUpdating, revision == currentRevision {
                    files = entries
                    info = details
                    diagnostics = details.diagnostics
                    issue = nil
                }
            } catch {
                guard !Task.isCancelled, generation == watchGeneration else { return }
                issue = EngineStatusPresentation.errorMessage(error)
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    /// 顶部与文件行使用同一批采样；只汇总所选文件，避免把任务快照和旧文件进度混用。
    func displayTask(_ task: DownloadTask) -> DownloadTask {
        guard currentID == task.engineTaskID, !files.isEmpty else { return task }
        var result = task
        let selected = files.filter { $0.priority > 0 }
        result.totalBytes = selected.reduce(0) { $0 + max(0, $1.size) }
        result.receivedBytes = selected.reduce(0) { $0 + min(max(0, $1.done), max(0, $1.size)) }
        return result
    }

    static func progress(for file: TorrentFileEntry) -> Double {
        file.size > 0 ? min(1, max(0, Double(file.done) / Double(file.size))) : 1
    }

    static func sourceRows(_ sources: TorrentPeerSources) -> [(title: String, count: Int)] {
        [
            (String(localized: "节点服务器（tracker）"), sources.tracker),
            (String(localized: "分布式网络"), sources.dht),
            (String(localized: "节点交换"), sources.pex),
            (String(localized: "局域网"), sources.lsd),
            (String(localized: "对方连入"), sources.incoming)
        ].filter { $0.1 > 0 }
    }

    static func trackerSummary(_ diagnostics: TorrentDiagnostics) -> String {
        String(localized: "可用 \(diagnostics.trackersAvailable) 个，失败 \(diagnostics.trackersFailed) 个")
    }

    static func trackerError(_ error: String?) -> String? {
        guard let error, !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let message = error.lowercased()
        if message.contains("timed out") || message.contains("timeout") {
            return String(localized: "节点服务器响应太慢，稍后会重试。")
        }
        if message.contains("resolve") || message.contains("host not found") || message.contains("name or service") {
            return String(localized: "暂时找不到节点服务器的地址，稍后会重试。")
        }
        if message.contains("certificate") || message.contains("ssl") || message.contains("tls") {
            return String(localized: "无法确认节点服务器的安全连接，稍后会重试。")
        }
        if message.contains("401") || message.contains("403") || message.contains("unauthor")
            || message.contains("not registered") || message.contains("unregistered") || message.contains("passkey") {
            return String(localized: "节点服务器未允许此任务连接，请检查种子是否仍可用。")
        }
        if message.contains("429") || message.contains("too many") {
            return String(localized: "节点服务器正忙，稍后会重试。")
        }
        return String(localized: "暂时无法连接节点服务器，稍后会重试。")
    }

    static func diskMessage(_ backlogged: Bool?) -> String {
        switch backlogged {
        case true: String(localized: "硬盘写入跟不上下载速度")
        case false: String(localized: "硬盘写入正常")
        case nil: String(localized: "正在检测硬盘写入情况")
        }
    }

    static func blockedClientsMessage(_ count: Int64) -> String? {
        count > 0 ? String(localized: "已屏蔽客户端 \(count) 次") : nil
    }

    func setDownloadMode(sequentialDownload: Bool, firstLastPriority: Bool) async {
        guard !isUpdating, let engine, let id = currentID else { return }
        let operationGeneration = generation
        isUpdating = true
        revision += 1
        defer {
            if generation == operationGeneration {
                isUpdating = false
                revision += 1
            }
        }
        do {
            try await engine.setDownloadMode(id, sequentialDownload: sequentialDownload, firstLastPriority: firstLastPriority)
            let details = try await engine.taskInfo(id)
            guard generation == operationGeneration, !Task.isCancelled else { return }
            info = details
            diagnostics = details.diagnostics
            issue = nil
        } catch {
            guard generation == operationGeneration else { return }
            issue = EngineStatusPresentation.errorMessage(error)
        }
    }

    static func priorities(
        for files: [TorrentFileEntry], index: Int, selected: Bool
    ) -> [Int]? {
        guard files.contains(where: { $0.index == index }) else { return nil }
        let priorities = files.map { $0.index == index ? (selected ? 4 : 0) : $0.priority }
        return priorities.contains(where: { $0 > 0 }) ? priorities : nil
    }

    func setSelected(_ selected: Bool, file: TorrentFileEntry) async {
        guard !isUpdating, let engine, let id = currentID,
              let priorities = Self.priorities(for: files, index: file.index, selected: selected) else { return }
        isUpdating = true
        let operationGeneration = generation
        revision += 1
        defer {
            if generation == operationGeneration {
                isUpdating = false
                revision += 1
            }
        }
        do {
            try await engine.setFilePriorities(id, priorities)
            let entries = try await engine.files(id)
            guard generation == operationGeneration, !Task.isCancelled else { return }
            files = entries
            issue = nil
        } catch {
            guard generation == operationGeneration else { return }
            issue = EngineStatusPresentation.errorMessage(error)
        }
    }

    #if DEBUG
    static func preview(
        info: TorrentTaskInfo? = nil, id: String? = nil,
        files: [TorrentFileEntry] = [TorrentFileEntry(index: 0, path: "Big Buck Bunny.mp4", size: 1_000_000_000, done: 160_000_000)]
    ) throws -> BitTorrentFilesModel {
        let model = BitTorrentFilesModel()
        model.isPreview = true
        model.currentID = id
        model.info = info
        model.files = files
        let data = Data("""
            {
                "connectedPeers": 12,
                "peerSources": { "tracker": 4, "dht": 6, "pex": 3, "lsd": 1, "incoming": 2 },
                "ipv4": 9, "ipv6": 3, "tcp": 8, "utp": 4,
                "trackersAvailable": 3, "trackersFailed": 1, "trackersPending": 2,
                "lastTrackerError": "Connection timed out",
                "diskBacklogged": true, "queuedDiskBytes": 67108864,
                "diskBlockedPeers": 2, "diskQueueLimit": 67108864,
                "blockedClientsCount": 5
            }
            """.utf8)
        model.diagnostics = try JSONDecoder().decode(TorrentDiagnostics.self, from: data)
        return model
    }
    #endif
}

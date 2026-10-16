import Foundation
import MuleeCore
import Observation

/// 节点和 tracker 与详情栏一起出现、消失；旧任务的迟到响应不能覆盖新任务。
@Observable
final class BitTorrentManagementModel {
    private(set) var trackers: [TorrentTrackerStatus] = []
    private(set) var peers: [TorrentPeer] = []
    private(set) var isUpdating = false
    var issue: String?
    private var engine: TorrentEngine?
    private var id: String?
    private var generation = 0
    private var revision = 0

    func watch(engine: TorrentEngine?, id: String?) async {
        generation += 1
        let token = generation
        self.engine = engine
        self.id = id
        trackers = []
        peers = []
        issue = nil
        isUpdating = false
        guard let engine, let id else { return }
        while !Task.isCancelled {
            let sampledRevision = revision
            do {
                let nodes = try await engine.peers(id)
                let servers = try await engine.trackers(id)
                guard !Task.isCancelled, generation == token else { return }
                if !isUpdating, revision == sampledRevision {
                    peers = nodes
                    trackers = servers
                    issue = nil
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                issue = EngineStatusPresentation.errorMessage(error)
            }
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
        }
    }

    var trackerConfigurations: [TorrentTracker] {
        trackers.map { TorrentTracker(url: $0.url, tier: $0.tier, subscription: $0.subscription) }
    }

    func saveTrackers(_ configurations: [TorrentTracker]) async {
        guard let engine, let id, !isUpdating else { return }
        if let problem = Self.trackerValidation(configurations.map(\.url)) {
            issue = problem
            return
        }
        let token = generation
        isUpdating = true
        revision += 1
        defer {
            if generation == token { isUpdating = false; revision += 1 }
        }
        do {
            try await engine.setTrackers(id, trackers: configurations)
            let servers = try await engine.trackers(id)
            guard generation == token else { return }
            trackers = servers
            issue = nil
        } catch {
            if generation == token { issue = EngineStatusPresentation.errorMessage(error) }
        }
    }

    func ban(_ address: String) async {
        guard let engine, !isUpdating else { return }
        let token = generation
        isUpdating = true
        revision += 1
        defer {
            if generation == token { isUpdating = false; revision += 1 }
        }
        do {
            try await engine.banIP(address)
            guard generation == token else { return }
            peers.removeAll { $0.address == address }
            issue = nil
        } catch {
            if generation == token { issue = EngineStatusPresentation.errorMessage(error) }
        }
    }

    static func trackerValidation(_ urls: [String]) -> String? {
        guard urls.count <= 50 else { return String(localized: "最多添加 50 个节点服务器，请删减后保存。") }
        guard Set(urls).count == urls.count else { return String(localized: "节点服务器地址重复，请保留一项。") }
        for text in urls {
            guard !text.contains(where: \.isWhitespace), let url = URLComponents(string: text),
                  ["http", "https", "udp"].contains(url.scheme?.lowercased() ?? ""),
                  let host = url.host, !host.isEmpty else {
                return String(localized: "节点服务器地址需要以 http://、https:// 或 udp:// 开头，并包含主机名。")
            }
        }
        return nil
    }

    static func renameValidation(_ name: String) -> String? {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else {
            return String(localized: "名称不能为空，也不能包含 / 或使用 .、..。")
        }
        return nil
    }

    static func renamedPath(_ path: String, name: String) -> String? {
        guard renameValidation(name) == nil else { return nil }
        let components = path.split(separator: "/").dropLast().map(String.init) + [name]
        return components.joined(separator: "/")
    }

    static func trackerState(_ tracker: TorrentTrackerStatus) -> String {
        if tracker.status == "disabled" { return String(localized: "已暂停 24 小时（连续失败）") }
        switch tracker.status {
        case "working": return String(localized: "连接正常")
        case "failed": return String(localized: "连接失败，稍后重试")
        default: return String(localized: "等待响应")
        }
    }

    static func trackerResult(_ tracker: TorrentTrackerStatus) -> String {
        if tracker.lastResult.isEmpty { return String(localized: "尚无结果") }
        if tracker.status == "working" { return String(localized: "宣告成功") }
        return BitTorrentFilesModel.trackerError(tracker.lastResult) ?? String(localized: "尚无结果")
    }

    static func peerAddress(_ peer: TorrentPeer) -> String {
        peer.address.contains(":") ? "[\(peer.address)]:\(peer.port)" : "\(peer.address):\(peer.port)"
    }

    static func peerProgress(_ peer: TorrentPeer) -> String {
        let progress = peer.progress.isFinite ? min(1, max(0, peer.progress)) : 0
        return progress.formatted(.percent.precision(.fractionLength(0)))
    }

    static func peerSpeed(_ bytes: Int64) -> String {
        max(0, bytes).formatted(.byteCount(style: .file)) + "/s"
    }

    static func peerSources(_ sources: [String]) -> String {
        sources.map {
            switch $0 {
            case "tracker": String(localized: "节点服务器")
            case "dht": String(localized: "分布式网络")
            case "pex": String(localized: "节点交换")
            case "lsd": String(localized: "局域网")
            case "incoming": String(localized: "对方连入")
            default: String(localized: "其他")
            }
        }.joined(separator: "、")
    }

    static func peerConnection(_ connection: String) -> String {
        connection == "utp" ? "UDP（uTP）" : "TCP"
    }
}

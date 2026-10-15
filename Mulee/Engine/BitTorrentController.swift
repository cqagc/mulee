import Foundation
import MuleeCore
import Observation

/// BT 的设置与会话监测。文件列表由选中任务的详情视图独立按需读取。
@Observable
final class BitTorrentController {
    let engine: TorrentEngine
    private weak var model: AppModel?
    private var configuration: TorrentEngineSettings
    private var isRunning = false
    private var monitor: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private var reachability = BitTorrentPortReachability()
    private var listenPort: Int?
    var issue: String?

    init(engine: TorrentEngine, model: AppModel, configuration: TorrentEngineSettings) {
        self.engine = engine
        self.model = model
        self.configuration = configuration
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        reachability = BitTorrentPortReachability()
        configure(configuration)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSession()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    func stop() {
        isRunning = false
        monitor?.cancel()
        monitor = nil
        configurationTask?.cancel()
        model?.networkStatus.bittorrentPortReachable = nil
    }

    func configure(_ configuration: TorrentEngineSettings) {
        if self.configuration.listenPort != configuration.listenPort {
            reachability = BitTorrentPortReachability()
            model?.networkStatus.bittorrentPortReachable = nil
        }
        self.configuration = configuration
        guard isRunning else { return }
        let previous = configurationTask
        configurationTask = Task { [weak self] in
            await previous?.value
            guard let self, self.isRunning, !Task.isCancelled else { return }
            do {
                try await self.engine.configure(configuration)
                self.issue = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.issue = EngineStatusPresentation.errorMessage(error)
            }
        }
    }

    func observePeers(in tasks: [DownloadTask]) {
        reachability.observePeers(tasks.contains { task in
            if case .bittorrent(_, _, let peers, _) = task.detail { return peers > 0 }
            return false
        })
    }

    func refreshSession() async {
        guard isRunning else { return }
        do {
            let status = try await engine.sessionStatus()
            guard isRunning, !Task.isCancelled else { return }
            if (listenPort != nil && listenPort != status.listenPort)
                || (reachability.sawIncoming && !status.hasIncomingConnections) {
                // 入站历史由 torrentd 在会话内累计；从有变无表示会话已经重启。
                reachability = BitTorrentPortReachability()
            }
            listenPort = status.listenPort
            model?.networkStatus.bittorrentPortReachable = reachability.observe(incoming: status.hasIncomingConnections)
            issue = nil
        } catch {
            guard isRunning, !Task.isCancelled else { return }
            reachability = BitTorrentPortReachability()
            listenPort = nil
            model?.networkStatus.bittorrentPortReachable = nil
            issue = EngineStatusPresentation.errorMessage(error)
        }
    }
}

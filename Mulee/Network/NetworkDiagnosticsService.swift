import Foundation
import MuleeCore
import Network
import Observation

/// UI 状态在主 actor；阻塞的系统与 DNS 查询由探测器放到并发执行器。
@Observable
final class NetworkDiagnosticsService {
    static let shared = NetworkDiagnosticsService()

    private(set) var snapshot = NetworkDiagnosticsSnapshot.unknown
    private(set) var isRefreshing = false
    @ObservationIgnored private let probe: any NetworkDiagnosticsProbing
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored private var pathTask: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var lastProbe: ContinuousClock.Instant?
    @ObservationIgnored private var refreshID: UUID?

    init(probe: any NetworkDiagnosticsProbing = SystemNetworkDiagnosticsProbe()) {
        self.probe = probe
    }

    func start(model: AppModel, monitorsPathChanges: Bool = true) {
        guard timerTask == nil else { return }
        self.model = model
        refresh()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(60)) } catch { return }
                self?.refresh()
            }
        }
        guard monitorsPathChanges else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        pathTask = Task { [weak self] in
            for await _ in monitor {
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        timerTask?.cancel()
        pathTask?.cancel()
        refreshTask?.cancel()
        pathMonitor?.cancel()
        timerTask = nil
        pathTask = nil
        refreshTask = nil
        refreshID = nil
        pathMonitor = nil
        isRefreshing = false
        lastProbe = nil
        model = nil
    }

    /// 路径事件和重复点击合并，DNS 至少间隔十秒。
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard refreshTask == nil else { return refreshTask }
        let id = UUID()
        refreshID = id
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.isRefreshing = true
            defer {
                if self.refreshID == id {
                    self.isRefreshing = false
                    self.refreshTask = nil
                    self.refreshID = nil
                }
            }
            if let last = self.lastProbe {
                do { try await ContinuousClock().sleep(until: last.advanced(by: .seconds(10))) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let result = await self.probe.probe()
            guard !Task.isCancelled else { return }
            self.lastProbe = .now
            self.snapshot = result
            self.model?.networkStatus.p2pRoutedThroughProxy = result.proxyKind == .tunnel
            if let engine = self.model?.bitTorrent?.engine {
                do {
                    let session = try await engine.sessionStatus()
                    guard !Task.isCancelled else { return }
                    self.model?.networkStatus.p2pExitIP = session.externalAddress
                } catch {
                    // 引擎可能尚未启动；旧出口不应在无法确认时继续显示。
                    self.model?.networkStatus.p2pExitIP = nil
                }
            }
        }
        return refreshTask
    }
}

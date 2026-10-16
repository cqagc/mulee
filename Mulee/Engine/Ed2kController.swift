import Foundation
import MuleeCore
import Observation
import OSLog

/// 电驴设置与网络监测；等待来源的任务始终由引擎快照接管。
@Observable
final class Ed2kController {
    let engine: Ed2kEngine
    private weak var model: AppModel?
    private var configuration: Ed2kEngineSettings
    private var generation: UUID?
    private var monitor: Task<Void, Never>?
    private var configurationTask: Task<Void, Never>?
    private static let logger = Logger(subsystem: "com.cqagc.mulee", category: "Ed2k")
    private var mappedPorts: ExtraPortMappings?
    private var recheckedMappings: ExtraPortMappings?
    var portMappings: [ExtraPortMappingStatus] = []
    var issue: String?

    init(engine: Ed2kEngine, model: AppModel, configuration: Ed2kEngineSettings) {
        self.engine = engine
        self.model = model
        self.configuration = configuration
    }

    func start() {
        guard generation == nil else { return }
        generation = UUID()
        configure(configuration)
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshNetwork()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    func stop() {
        generation = nil
        monitor?.cancel()
        monitor = nil
        configurationTask?.cancel()
        mappedPorts = nil
        recheckedMappings = nil
        portMappings = []
        model?.bitTorrent?.setEd2kPortMappings(ExtraPortMappings())
        model?.updateEd2kNetworkStatus(id: .disconnected, kad: .disconnected)
    }

    func configure(_ configuration: Ed2kEngineSettings) {
        if self.configuration.tcpPort != configuration.tcpPort || self.configuration.udpPort != configuration.udpPort {
            mappedPorts = nil
            recheckedMappings = nil
            portMappings = []
            model?.bitTorrent?.setEd2kPortMappings(ExtraPortMappings())
        }
        self.configuration = configuration
        guard let token = generation else { return }
        let previous = configurationTask
        configurationTask = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == token, !Task.isCancelled else { return }
            do {
                try await self.engine.configure(configuration, preserveBandwidth: true)
                guard self.generation == token, !Task.isCancelled else { return }
                self.issue = nil
                await self.refreshNetwork()
            } catch {
                guard self.generation == token, !Task.isCancelled else { return }
                self.issue = EngineStatusPresentation.errorMessage(error, kind: .ed2k)
            }
        }
    }

    func clearPortMappings() {
        portMappings = []
        recheckedMappings = nil
    }

    func updatePortMappings(_ status: TorrentSessionStatus) async {
        guard generation != nil else { return }
        portMappings = status.portMappingEnabled == true ? status.extraPortMappings ?? [] : []
        guard let ports = mappedPorts else { return }
        let complete = ports.tcp.allSatisfy { port in
            portMappings.contains { $0.protocol == "tcp" && $0.localPort == port && $0.succeeded == true }
        } && ports.udp.allSatisfy { port in
            portMappings.contains { $0.protocol == "udp" && $0.localPort == port && $0.succeeded == true }
        }
        guard complete, recheckedMappings != ports else {
            if !complete { recheckedMappings = nil }
            return
        }
        recheckedMappings = ports
        do { try await engine.recheckConnectivity() } catch {
            recheckedMappings = nil
            Self.logger.warning("电驴连接复查暂未完成：\(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshNetwork() async {
        guard let token = generation else { return }
        do {
            let status = try await engine.networkStatus()
            guard generation == token, !Task.isCancelled else { return }
            model?.updateEd2kNetworkStatus(id: status.ed2kID, kad: status.kad)
            do {
                let ports = try await engine.listeningPorts()
                guard generation == token, !Task.isCancelled else { return }
                if mappedPorts != ports {
                    mappedPorts = ports
                    recheckedMappings = nil
                    portMappings = []
                }
                model?.bitTorrent?.setEd2kPortMappings(ports)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                mappedPorts = nil
                clearPortMappings()
                model?.bitTorrent?.setEd2kPortMappings(ExtraPortMappings())
                issue = EngineStatusPresentation.errorMessage(error, kind: .ed2k)
            }
        } catch {
            guard generation == token, !Task.isCancelled else { return }
            mappedPorts = nil
            recheckedMappings = nil
            portMappings = []
            model?.bitTorrent?.setEd2kPortMappings(ExtraPortMappings())
            model?.updateEd2kNetworkStatus(id: .disconnected, kad: .disconnected)
            Self.logger.warning("读取电驴网络状态暂未完成：\(error.localizedDescription, privacy: .public)")
        }
    }
}

import Foundation
import MuleeCore

/// 引擎与侧边栏网络状态的可测试展示文案。
enum EngineStatusPresentation {
    static func title(for state: EngineState) -> String {
        switch state {
        case .running: "HTTP 就绪"
        case .unavailable: "未接入"
        case .failed(let reason): reason.count > 22 ? String(reason.prefix(22)) + "…" : reason
        }
    }

    nonisolated static func errorMessage(_ error: any Error) -> String {
        switch error {
        case EngineError.binaryNotFound: "未找到 aria2"
        case EngineError.notRunning: "下载引擎未运行"
        case EngineError.launchFailed(let reason): "引擎启动失败：\(reason)"
        case EngineError.rpc(let code, let message): "\(message)（\(code)）"
        case EngineError.invalidResponse(let reason): "引擎响应异常：\(reason)"
        case EngineError.unsupportedLink: "引擎不支持此链接"
        default: error.localizedDescription
        }
    }

    static func ed2k(_ status: NetworkStatus.Ed2kID) -> String {
        switch status {
        case .high: "High ID"
        case .low: "Low ID"
        case .disconnected: "未启用"
        }
    }

    static func kad(_ status: NetworkStatus.KadState) -> String {
        switch status {
        case .open: "已连接"
        case .firewalled: "受限"
        case .disconnected: "未启用"
        }
    }

    static func port(_ reachable: Bool?) -> String {
        switch reachable {
        case true: "可达"
        case false: "不可达"
        case nil: "未启用"
        }
    }

    static func exit(_ status: NetworkStatus) -> String {
        guard status.p2pExitIP != nil else { return "未检测" }
        return status.p2pRoutedThroughProxy ? "走代理" : "直连"
    }
}

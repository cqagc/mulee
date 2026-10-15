import Foundation
import MuleeCore

/// 引擎与侧边栏网络状态的可测试展示文案。
enum EngineStatusPresentation {
    static func title(for state: EngineState) -> String {
        switch state {
        case .running: String(localized: "HTTP 就绪")
        case .preparing: String(localized: "正在准备")
        case .missingFFmpeg: String(localized: "缺少 ffmpeg，音视频合并不可用")
        case .unavailable: String(localized: "未接入")
        case .failed(let reason): reason.count > 22 ? String(reason.prefix(22)) + "…" : reason
        }
    }

    static func videoTitle(for state: EngineState) -> String {
        switch state {
        case .running: String(localized: "就绪")
        case .preparing: String(localized: "正在准备")
        case .missingFFmpeg: String(localized: "缺少 ffmpeg，音视频合并不可用")
        case .unavailable: String(localized: "未接入")
        case .failed(let reason): String(localized: "启动失败：\(reason)")
        }
    }

    static func videoReadyState(ffmpegURL: URL?) -> EngineState {
        ffmpegURL == nil ? .missingFFmpeg : .running
    }

    nonisolated static func errorMessage(_ error: any Error, kind: TaskKind? = nil) -> String {
        switch error {
        case EngineError.binaryNotFound:
            switch kind {
            case .ed2k: String(localized: "未找到电驴下载工具")
            case .bittorrent: String(localized: "未找到 BT 下载工具")
            default: String(localized: "未找到 aria2")
            }
        case EngineError.notRunning: String(localized: "下载引擎未运行")
        case EngineError.launchFailed(let reason): String(localized: "引擎启动失败：\(reason)")
        case EngineError.rpc(let code, let message): "\(message)（\(code)）"
        case EngineError.invalidResponse(let reason): String(localized: "引擎响应异常：\(reason)")
        case EngineError.unsupportedLink: String(localized: "引擎不支持此链接")
        default: error.localizedDescription
        }
    }

    static func ed2k(_ status: NetworkStatus.Ed2kID) -> String {
        switch status {
        case .high: String(localized: "可连入")
        case .low: String(localized: "连入受限")
        case .disconnected: String(localized: "未连接")
        }
    }

    static func kad(_ status: NetworkStatus.KadState) -> String {
        switch status {
        case .open: String(localized: "开放")
        case .firewalled: String(localized: "受限")
        case .disconnected: String(localized: "未连接")
        }
    }

    static func port(_ reachable: Bool?) -> String {
        switch reachable {
        case true: String(localized: "可达")
        case false: String(localized: "不可达")
        case nil: String(localized: "未启用")
        }
    }

    static func exit(_ status: NetworkStatus) -> String {
        guard status.p2pExitIP != nil else { return String(localized: "未检测") }
        return status.p2pRoutedThroughProxy ? String(localized: "走代理") : String(localized: "直连")
    }
}

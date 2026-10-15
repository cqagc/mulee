import Foundation
import MuleeCore

/// 设置·网络页的文案与异常判断。纯函数，方便测试。
enum NetworkPresentation {
    /// 一段状态文案，以及它是否属于「需要留意」的异常状态（界面用琥珀色）。
    struct Line: Equatable {
        var text: String
        var isAbnormal: Bool
    }

    /// 遮挡出口 IP：IPv4 保留前两段，IPv6 保留前两组；nil 或非法返回「未知」。
    static func maskedIP(_ ip: String?) -> String {
        guard let ip else { return "未知" }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let parts = ip.split(separator: ".")
            return "\(parts[0]).\(parts[1]).x.x"
        }
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let groups = ip.split(separator: ":", omittingEmptySubsequences: false)
            guard groups.count >= 2, !groups[0].isEmpty, !groups[1].isEmpty else { return "未知" }
            return "\(groups[0]):\(groups[1]):x:x"
        }
        return "未知"
    }

    static func ed2kID(_ id: NetworkStatus.Ed2kID) -> Line {
        switch id {
        case .high: Line(text: "High ID", isAbnormal: false)
        case .low: Line(text: "Low ID", isAbnormal: true)
        case .disconnected: Line(text: "未连接", isAbnormal: true)
        }
    }

    /// Kad 右侧的简短标签。
    static func kadBadge(_ state: NetworkStatus.KadState) -> Line {
        switch state {
        case .open: Line(text: "正常", isAbnormal: false)
        case .firewalled: Line(text: "受限", isAbnormal: true)
        case .disconnected: Line(text: "未连接", isAbnormal: true)
        }
    }

    /// Kad 行下方的说明。
    static func kadDescription(_ state: NetworkStatus.KadState) -> String {
        switch state {
        case .open: "已连接"
        case .firewalled: "已连接，但外部暂时无法主动连入"
        case .disconnected: "未连接"
        }
    }

    static func bittorrentPort(reachable: Bool?) -> Line {
        switch reachable {
        case .some(true): Line(text: "可连入", isAbnormal: false)
        case .some(false): Line(text: "无法连入", isAbnormal: true)
        case .none: Line(text: "未确认", isAbnormal: false)
        }
    }

    /// UPnP / NAT-PMP 映射结果；未启用时为 nil（不显示标签）。
    static func portMapping(succeeded: Bool?) -> Line? {
        switch succeeded {
        case .some(true): Line(text: "已映射", isAbnormal: false)
        case .some(false): Line(text: "映射失败", isAbnormal: true)
        case .none: nil
        }
    }
}

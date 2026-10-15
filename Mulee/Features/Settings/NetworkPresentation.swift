import Foundation
import MuleeCore

/// 设置·网络页的文案与异常判断。纯函数，方便测试。
enum NetworkPresentation {
    static let rules = "PROCESS-NAME,amuled,DIRECT\nPROCESS-NAME,mulee-torrentd,DIRECT"
    static let proxyCardTitle = String(localized: "是否走代理")
    static let portCardTitle = String(localized: "端口能否从外部连入")
    static let proxyWarning = String(localized: "代理软件可能接管了下载连接")
    static let copyRules = String(localized: "复制 Stash / Clash 规则")
    static let recheck = String(localized: "重新检测")
    static let checking = String(localized: "正在检测…")
    static let rulesCopied = String(localized: "规则已复制")
    static let instructionsCopied = String(localized: "说明已复制")
    static let copyInstructions = String(localized: "复制端口转发说明")
    static let processRecognition = String(localized: "Clash Verge / mihomo 需要开启进程识别（find-process-mode），让按进程名匹配的规则生效。")
    static let fakeIPAdvice = String(localized: "域名解析使用了代理软件的虚拟地址。某些配置下，仅加直连规则仍不能连接来源；可在代理软件里为下载来源域名关闭虚拟地址解析，再重新检测。")
    static let differentSubnet = String(localized: "你的电脑和路由器不在同一网段，自动映射不起作用。需要由网络管理员手工转发端口。")
    static let unknownSubnet = String(localized: "暂时无法确认电脑和路由器是否在同一网段。")
    static let mappingTitle = String(localized: "BT 自动端口映射")
    static let mappingAdvice = String(localized: "路由器支持时，BT 引擎会尝试自动打开端口；电驴端口需要在路由器里手工转发。")
    static let portImpact = String(localized: "外部暂时无法主动连入时，仍可尝试连接其他来源，但能找到的来源可能较少，速度也可能较慢。")
    static let portPending = String(localized: "尚未连接或未确认的端口暂时无法判断，等待连接后再查看。")
    static let portsOpen = String(localized: "这些连接已收到外部可连入的证据，更容易找到来源。")
    static let btPortTitle = String(localized: "BT 端口")
    static let ed2kTCPTitle = String(localized: "电驴 TCP 端口")
    static let ed2kUDPTitle = String(localized: "电驴 UDP 端口")

    static func proxyTitle(_ kind: NetworkDiagnosticsSnapshot.ProxyKind) -> String {
        switch kind {
        case .unknown: String(localized: "代理状态尚未确认")
        case .none: String(localized: "未发现代理接管")
        case .system: String(localized: "开启了系统网页代理")
        case .tunnel: String(localized: "虚拟网卡可能接管了下载连接")
        }
    }

    static func proxyDescription(_ kind: NetworkDiagnosticsSnapshot.ProxyKind) -> String {
        switch kind {
        case .unknown: String(localized: "部分网络信息暂时无法读取。点击重新检测，确认 BT 和电驴的连接是否受到代理影响。")
        case .none: String(localized: "当前未发现代理接管的迹象。BT 和电驴仍需要有可用来源，端口是否可连入可在下方查看。")
        case .system: String(localized: "系统代理只影响网页类连接，BT 和电驴不受这项设置影响。端口是否可连入可在下方查看。")
        case .tunnel: String(localized: "BT 和电驴的流量现在很可能被代理软件接管了。代理节点通常不支持这类连接，所以可能找不到来源、速度很慢。在代理规则里加上下面两行，让它们直连后再检测。")
        }
    }

    static func portSummary(_ status: NetworkStatus) -> String {
        if status.bittorrentPortReachable == false || status.ed2kID == .low || status.kad == .firewalled {
            return portImpact
        }
        if status.bittorrentPortReachable == nil || status.ed2kID == .disconnected || status.kad == .disconnected {
            return portPending
        }
        return portsOpen
    }

    static func forwardingInstructions(btPort: Int, tcpPort: Int, udpPort: Int, network: NetworkDiagnosticsSnapshot) -> String {
        let target = network.localIP.map { String(localized: "转发到这台电脑的局域网地址 \($0)。") }
            ?? String(localized: "暂时未读到本机局域网地址，请连接局域网后重新检测，再确认转发目标。")
        let router = network.gateway.map { String(localized: "打开路由器（\($0)）的管理页面，找到端口转发设置。") }
            ?? String(localized: "打开路由器管理页面，找到端口转发设置；网关地址暂时无法读取。")
        let subnet: String
        switch network.isOnGatewaySubnet {
        case .some(false): subnet = differentSubnet
        case .some(true): subnet = String(localized: "电脑和路由器在同一网段。若自动映射未生效，可以手工转发。")
        case .none: subnet = unknownSubnet
        }
        return [router, String(localized: "BT：TCP / UDP \(btPort.formatted(.number.grouping(.never)))"),
                String(localized: "电驴：TCP \(tcpPort.formatted(.number.grouping(.never)))、UDP \(udpPort.formatted(.number.grouping(.never)))"),
                target, String(localized: "外部端口与电脑端口填写相同的端口号。"), subnet,
                String(localized: "转发后等待来源连接，再查看端口状态。")].joined(separator: "\n")
    }

    static func exitDescription(_ ip: String?) -> String {
        String(localized: "下载连接出口：\(maskedIP(ip))")
    }

    /// 一段状态文案，以及它是否属于「需要留意」的异常状态（界面用琥珀色）。
    struct Line: Equatable {
        var text: String
        var isAbnormal: Bool
    }

    /// 遮挡出口 IP：IPv4 保留前两段，IPv6 保留前两组；nil 或非法返回「未知」。
    static func maskedIP(_ ip: String?) -> String {
        guard let ip else { return String(localized: "未知") }
        var v4 = in_addr()
        var v6 = in6_addr()
        if inet_pton(AF_INET, ip, &v4) == 1 {
            let parts = ip.split(separator: ".")
            return "\(parts[0]).\(parts[1]).x.x"
        }
        if inet_pton(AF_INET6, ip, &v6) == 1 {
            let groups = ip.split(separator: ":", omittingEmptySubsequences: false)
            guard groups.count >= 2, !groups[0].isEmpty, !groups[1].isEmpty else { return String(localized: "未知") }
            return "\(groups[0]):\(groups[1]):x:x"
        }
        return String(localized: "未知")
    }

    static func ed2kID(_ id: NetworkStatus.Ed2kID) -> Line {
        switch id {
        case .high: Line(text: String(localized: "可从外部连入"), isAbnormal: false)
        case .low: Line(text: String(localized: "暂时无法从外部连入"), isAbnormal: true)
        case .disconnected: Line(text: String(localized: "尚未连接，暂无法判断"), isAbnormal: false)
        }
    }

    /// 侧边栏空间小，和「BT 端口」一样只用三个短词。
    static func sidebarReachability(ed2k id: NetworkStatus.Ed2kID) -> String {
        switch id {
        case .high: String(localized: "可连入")
        case .low: String(localized: "无法连入")
        case .disconnected: String(localized: "未连接")
        }
    }

    static func sidebarReachability(kad state: NetworkStatus.KadState) -> String {
        switch state {
        case .open: String(localized: "可连入")
        case .firewalled: String(localized: "无法连入")
        case .disconnected: String(localized: "未连接")
        }
    }

    /// Kad 右侧的简短标签。
    static func kadBadge(_ state: NetworkStatus.KadState) -> Line {
        switch state {
        case .open: Line(text: String(localized: "可从外部连入"), isAbnormal: false)
        case .firewalled: Line(text: String(localized: "暂时无法从外部连入"), isAbnormal: true)
        case .disconnected: Line(text: String(localized: "尚未连接，暂无法判断"), isAbnormal: false)
        }
    }

    /// Kad 行下方的说明。
    static func kadDescription(_ state: NetworkStatus.KadState) -> String {
        switch state {
        case .open: String(localized: "已连接")
        case .firewalled: String(localized: "已连接，但外部暂时无法主动连入")
        case .disconnected: String(localized: "未连接")
        }
    }

    static func bittorrentPort(reachable: Bool?) -> Line {
        switch reachable {
        case .some(true): Line(text: String(localized: "可连入"), isAbnormal: false)
        case .some(false): Line(text: String(localized: "无法连入"), isAbnormal: true)
        case .none: Line(text: String(localized: "未确认"), isAbnormal: false)
        }
    }

    /// UPnP / NAT-PMP 映射结果；未启用时为 nil（不显示标签）。
    static func portMapping(succeeded: Bool?) -> Line? {
        switch succeeded {
        case .some(true): Line(text: String(localized: "已映射"), isAbnormal: false)
        case .some(false): Line(text: String(localized: "暂未自动打开端口"), isAbnormal: true)
        case .none: nil
        }
    }
}

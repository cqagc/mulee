import MuleeCore
import Testing
@testable import Mulee

@Suite struct NetworkDiagnosticsPresentationTests {
    @Test func copiedRulesAreExact() {
        #expect(NetworkPresentation.rules == "PROCESS-NAME,amuled,DIRECT")
        #expect(NetworkPresentation.processRecognition.contains("仅在电驴连接受影响时"))
    }

    @Test func proxyDetectionExplainsAutomaticBTRecoveryWithoutClaimingFailure() {
        let text = NetworkPresentation.proxyDescription(.tunnel)
        #expect(text.contains("BT 会自动尝试处理代理虚拟地址"))
        #expect(text.contains("检测到代理并不代表下载受影响"))
        #expect(NetworkPresentation.fakeIPAdvice.contains("无需额外设置"))
        #expect(NetworkPresentation.fakeIPAdvice.contains("使用域名的服务器无法连接"))
        #expect(!NetworkPresentation.proxyWarning.contains("接管了下载连接"))
    }

    @Test func forwardingUsesConfiguredPortsAndInterfaceAddress() {
        let network = NetworkDiagnosticsSnapshot(localIP: "198.51.100.4", subnetMask: "255.255.255.0", gateway: "203.0.113.1")
        let text = instructions(network)
        #expect(text.contains("TCP / UDP 52001"))
        #expect(text.contains("TCP 42002、UDP 42003"))
        #expect(text.contains("198.51.100.4"))
        #expect(text.contains("203.0.113.1"))
        #expect(text.contains(NetworkPresentation.differentSubnet))
        let unknown = instructions(.unknown)
        #expect(unknown.contains("暂时未读到本机局域网地址"))
        #expect(unknown.contains(NetworkPresentation.unknownSubnet))
    }

    @Test func allPortCombinationsHaveClearConsequences() {
        for bt in [true, false, nil] as [Bool?] {
            for ed2k in [NetworkStatus.Ed2kID.high, .low, .disconnected] {
                for kad in [NetworkStatus.KadState.open, .firewalled, .disconnected] {
                    let status = status(bt: bt, ed2k: ed2k, kad: kad)
                    let text = NetworkPresentation.portSummary(status)
                    if bt == false || ed2k == .low || kad == .firewalled {
                        #expect(text == NetworkPresentation.portImpact)
                    } else if bt == nil || ed2k == .disconnected || kad == .disconnected {
                        #expect(text == NetworkPresentation.portPending)
                    } else {
                        #expect(text == NetworkPresentation.portsOpen)
                    }
                }
            }
        }
        #expect(NetworkPresentation.ed2kID(.low).text == "暂时无法从外部连入")
        #expect(NetworkPresentation.kadBadge(.firewalled).text == "暂时无法从外部连入")
        #expect(NetworkPresentation.ed2kID(.disconnected).text == "尚未连接，暂无法判断")
        #expect(NetworkPresentation.bittorrentPort(reachable: nil).text == "未确认")
    }

    @Test func allDiagnosticCopyAvoidsTechnicalJargon() {
        var copy = [NetworkPresentation.rules, NetworkPresentation.proxyCardTitle, NetworkPresentation.portCardTitle,
                    NetworkPresentation.proxyWarning, NetworkPresentation.copyRules, NetworkPresentation.recheck,
                    NetworkPresentation.checking, NetworkPresentation.rulesCopied, NetworkPresentation.instructionsCopied,
                    NetworkPresentation.copyInstructions, NetworkPresentation.processRecognition, NetworkPresentation.fakeIPAdvice,
                    NetworkPresentation.differentSubnet, NetworkPresentation.unknownSubnet, NetworkPresentation.mappingTitle,
                    NetworkPresentation.mappingAdvice, NetworkPresentation.mappingDisabled,
                    NetworkPresentation.mappingPending, NetworkPresentation.ed2kMappingTitle, NetworkPresentation.portImpact, NetworkPresentation.portPending,
                    NetworkPresentation.portsOpen, NetworkPresentation.btPortTitle, NetworkPresentation.ed2kTCPTitle,
                    NetworkPresentation.ed2kUDPTitle, NetworkPresentation.exitDescription(nil),
                    NetworkPresentation.exitDescription("192.0.2.3"), NetworkPresentation.maskedIP("2001:db8::1")]
        for kind in NetworkDiagnosticsSnapshot.ProxyKind.allCases {
            copy += [NetworkPresentation.proxyTitle(kind), NetworkPresentation.proxyDescription(kind)]
        }
        for id in [NetworkStatus.Ed2kID.high, .low, .disconnected] {
            copy.append(NetworkPresentation.ed2kID(id).text)
        }
        for kad in [NetworkStatus.KadState.open, .firewalled, .disconnected] {
            copy += [NetworkPresentation.kadBadge(kad).text, NetworkPresentation.kadDescription(kad)]
        }
        for reachable in [true, false, nil] as [Bool?] {
            copy.append(NetworkPresentation.bittorrentPort(reachable: reachable).text)
            if let mapping = NetworkPresentation.portMapping(succeeded: reachable) { copy.append(mapping.text) }
        }
        for network in [NetworkDiagnosticsSnapshot.unknown,
                        NetworkDiagnosticsSnapshot(localIP: "192.0.2.2", subnetMask: "255.255.255.0", gateway: "192.0.2.1"),
                        NetworkDiagnosticsSnapshot(localIP: "203.0.113.2", subnetMask: "255.255.255.0", gateway: "192.0.2.1")] {
            copy.append(instructions(network))
        }
        for text in copy {
            for term in ["Low ID", "High ID", "firewalled", "NAT", "UPnP"] {
                #expect(!text.localizedCaseInsensitiveContains(term), "文案包含禁用术语：\(text)")
            }
        }
    }

    @Test func missingPublicIPv4ExplainsImpactAndNeverRecommendsForwarding() {
        let network = NetworkDiagnosticsSnapshot(routerWANAddress: "10.0.0.1")
        #expect(network.publicIPv4Status == .noPublicIPv4)
        #expect(NetworkPresentation.publicIPv4Line(network).isAbnormal)
        for bt in [true, false, nil] as [Bool?] {
            let status = status(bt: bt, ed2k: .low, kad: .firewalled)
            let summary = NetworkPresentation.portSummary(status, network: network)
            #expect(summary.contains(NetworkPresentation.noPublicIPv4))
            #expect(summary.contains(NetworkPresentation.noPublicIPv4Impact))
            #expect(summary.contains(NetworkPresentation.publicIPv4Remedy))
            #expect(summary.contains(NetworkPresentation.btUnaffected) == (bt == true))
            #expect(NetworkPresentation.ed2kExplanation(status, network: network) == summary)
            #expect(NetworkPresentation.ed2kExplanation(status, network: network, kad: true) == summary)
            #expect(!summary.contains("手工转发"))
            #expect(!summary.contains("打开路由器"))
            for term in ["Low ID", "High ID", "firewalled", "CGNAT", "UPnP", "NAT-PMP"] {
                #expect(!summary.localizedCaseInsensitiveContains(term))
            }
        }
        let copied = instructions(network)
        #expect(copied.contains(NetworkPresentation.publicIPv4Remedy))
        #expect(!copied.contains("TCP / UDP"))
        #expect(!copied.contains("手工转发"))
        #expect(!copied.contains("打开路由器"))
    }

    @Test func unknownWANPreservesExistingCopyAndEvidence() {
        let status = status(bt: nil, ed2k: .disconnected, kad: .disconnected)
        for network in [NetworkDiagnosticsSnapshot.unknown, NetworkDiagnosticsSnapshot(routerWANAddress: "invalid")] {
            #expect(network.publicIPv4Status == .unknown)
            #expect(NetworkPresentation.publicIPv4Line(network).text == "未确认")
            #expect(!NetworkPresentation.publicIPv4Line(network).isAbnormal)
            #expect(NetworkPresentation.portSummary(status, network: network) == NetworkPresentation.portPending)
            #expect(NetworkPresentation.ed2kExplanation(status, network: network) == NetworkPresentation.ed2kID(.disconnected).text)
            #expect(NetworkPresentation.ed2kExplanation(status, network: network, kad: true) == NetworkPresentation.kadDescription(.disconnected))
            #expect(instructions(network).contains("找到端口转发设置"))
            #expect(!instructions(network).contains(NetworkPresentation.noPublicIPv4))
        }
    }

    private func instructions(_ network: NetworkDiagnosticsSnapshot) -> String {
        NetworkPresentation.forwardingInstructions(btPort: 52001, tcpPort: 42002, udpPort: 42003, network: network)
    }

    private func status(bt: Bool?, ed2k: NetworkStatus.Ed2kID, kad: NetworkStatus.KadState) -> NetworkStatus {
        NetworkStatus(ed2kID: ed2k, kad: kad, bittorrentPortReachable: bt,
                      p2pRoutedThroughProxy: false, p2pExitIP: nil, portMappingSucceeded: nil)
    }
}

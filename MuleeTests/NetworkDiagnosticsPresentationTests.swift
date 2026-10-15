import MuleeCore
import Testing
@testable import Mulee

@Suite struct NetworkDiagnosticsPresentationTests {
    @Test func copiedRulesAreExact() {
        #expect(NetworkPresentation.rules == "PROCESS-NAME,amuled,DIRECT\nPROCESS-NAME,mulee-torrentd,DIRECT")
        #expect(NetworkPresentation.processRecognition.contains("find-process-mode"))
    }

    @Test func forwardingUsesConfiguredPortsAndInterfaceAddress() {
        let network = NetworkDiagnosticsSnapshot(localIP: "10.2.3.4", subnetMask: "255.255.255.0", gateway: "10.2.4.1")
        let text = instructions(network)
        #expect(text.contains("TCP / UDP 52001"))
        #expect(text.contains("TCP 42002、UDP 42003"))
        #expect(text.contains("10.2.3.4"))
        #expect(text.contains("10.2.4.1"))
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
                    NetworkPresentation.mappingAdvice, NetworkPresentation.portImpact, NetworkPresentation.portPending,
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
                        NetworkDiagnosticsSnapshot(localIP: "10.0.0.2", subnetMask: "255.255.255.0", gateway: "10.0.0.1"),
                        NetworkDiagnosticsSnapshot(localIP: "10.0.1.2", subnetMask: "255.255.255.0", gateway: "10.0.0.1")] {
            copy.append(instructions(network))
        }
        for text in copy {
            for term in ["Low ID", "High ID", "firewalled", "NAT", "UPnP"] {
                #expect(!text.localizedCaseInsensitiveContains(term), "文案包含禁用术语：\(text)")
            }
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

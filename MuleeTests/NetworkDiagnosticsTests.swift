import MuleeCore
import Testing
@testable import Mulee

@Suite struct NetworkDiagnosticsTests {
    @Test(arguments: [false, true], [false, true])
    func proxyCombinations(tunnel: Bool, fakeIP: Bool) {
        for system in [false, true] {
            let snapshot = NetworkDiagnosticsSnapshot(
                routedThroughTunnel: tunnel,
                trackerAddresses: [fakeIP ? "198.19.255.254" : "192.0.2.1"],
                systemProxyEnabled: system
            )
            let expected: NetworkDiagnosticsSnapshot.ProxyKind = tunnel || fakeIP ? .tunnel : system ? .system : .none
            #expect(snapshot.proxyKind == expected)
            #expect(snapshot.usesFakeIP == fakeIP)
        }
    }

    @Test func incompleteEvidenceStaysUnknown() {
        #expect(NetworkDiagnosticsSnapshot.unknown.proxyKind == .unknown)
        #expect(NetworkDiagnosticsSnapshot(routedThroughTunnel: false, systemProxyEnabled: true).proxyKind == .unknown)
        #expect(NetworkDiagnosticsSnapshot(routedThroughTunnel: true).proxyKind == .tunnel)
        #expect(NetworkDiagnosticsSnapshot(trackerAddresses: ["198.18.0.1"]).proxyKind == .tunnel)
    }

    @Test(arguments: ["198.18.0.0", "198.18.255.255", "198.19.0.0", "198.19.255.255"])
    func fakeIPRange(address: String) {
        #expect(NetworkDiagnosticsSnapshot.isFakeIP(address))
    }

    @Test(arguments: ["198.17.255.255", "198.20.0.0", "198.19.256.1", "198.18", "::1", "2001:db8::1"])
    func otherAddresses(address: String) {
        #expect(!NetworkDiagnosticsSnapshot.isFakeIP(address))
    }

    @Test func subnetUsesMaskRatherThanAddressPrefix() {
        #expect(NetworkDiagnosticsSnapshot.sameSubnet(localIP: "10.2.3.4", mask: "255.255.0.0", gateway: "10.2.9.1") == true)
        #expect(NetworkDiagnosticsSnapshot.sameSubnet(localIP: "192.168.1.130", mask: "255.255.255.128", gateway: "192.168.1.1") == false)
        #expect(NetworkDiagnosticsSnapshot.sameSubnet(localIP: "192.168.2.3", mask: "255.255.255.0", gateway: "192.168.1.1") == false)
        #expect(NetworkDiagnosticsSnapshot.sameSubnet(localIP: nil, mask: "255.255.255.0", gateway: "10.0.0.1") == nil)
        #expect(NetworkDiagnosticsSnapshot.sameSubnet(localIP: "10.0.0.2", mask: "255.0.255.0", gateway: "10.0.0.1") == nil)
        #expect(NetworkDiagnosticsSnapshot.sameSubnet(localIP: "bad", mask: "255.255.255.0", gateway: "10.0.0.1") == nil)
    }

    @Test func injectedProbeUpdatesOnlyDiagnosticFields() async {
        let result = NetworkDiagnosticsSnapshot(routedThroughTunnel: true, trackerAddresses: ["198.18.0.1"],
                                                routerWANAddress: "10.0.0.1")
        let probe = NetworkDiagnosticsProbeStub(result: result)
        let service = NetworkDiagnosticsService(probe: probe)
        let status = NetworkStatus(ed2kID: .high, kad: .open, bittorrentPortReachable: true,
                                   p2pRoutedThroughProxy: false, p2pExitIP: nil, portMappingSucceeded: nil)
        let model = AppModel(tasks: [], networkStatus: status)
        service.start(model: model, monitorsPathChanges: false)
        await service.refresh()?.value
        service.stop()
        #expect(await probe.calls == 1)
        #expect(service.snapshot == result)
        #expect(service.snapshot.publicIPv4Status == .noPublicIPv4)
        #expect(model.networkStatus.p2pRoutedThroughProxy)
        #expect(model.networkStatus.ed2kID == .high)
        #expect(model.networkStatus.kad == .open)
        #expect(model.networkStatus.bittorrentPortReachable == true)
    }
}

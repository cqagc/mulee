import Foundation
import Testing
@testable import Mulee

@Suite struct NetworkDiagnosticsLiveTests {
    /// 默认跳过；只读实测，不启动下载引擎或改代理设置。
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MULEE_NETWORK_DIAGNOSTICS_LIVE"] == "1"))
    func systemProbe() async {
        let snapshot = await SystemNetworkDiagnosticsProbe().probe()
        print("NETWORK_DIAGNOSTICS_LIVE kind=\(snapshot.proxyKind) utun=\(String(describing: snapshot.routedThroughTunnel)) fakeIP=\(snapshot.usesFakeIP) systemProxy=\(String(describing: snapshot.systemProxyEnabled)) tracker=\(snapshot.trackerAddresses ?? []) local=\(snapshot.localIP ?? "unknown") mask=\(snapshot.subnetMask ?? "unknown") gateway=\(snapshot.gateway ?? "unknown") sameSubnet=\(String(describing: snapshot.isOnGatewaySubnet))")
        #expect(snapshot.routedThroughTunnel != nil)
    }
}

import MuleeCore
import Testing
@testable import Mulee

@Suite struct NetworkPresentationTests {
    @Test func masksIPv4() {
        #expect(NetworkPresentation.maskedIP("203.0.113.71") == "118.166.x.x")
    }

    @Test func masksIPv6() {
        #expect(NetworkPresentation.maskedIP("2001:db8:85a3::8a2e:370:7334") == "2001:db8:x:x")
    }

    @Test(arguments: [nil, "", "abc", "1.2.3", "999.1.1.1", "::1"])
    func invalidIPIsUnknown(_ ip: String?) {
        #expect(NetworkPresentation.maskedIP(ip) == "未知")
    }

    @Test func ed2kStates() {
        #expect(NetworkPresentation.ed2kID(.high) == .init(text: "可从外部连入", isAbnormal: false))
        #expect(NetworkPresentation.ed2kID(.low) == .init(text: "暂时无法从外部连入", isAbnormal: true))
        #expect(!NetworkPresentation.ed2kID(.disconnected).isAbnormal)
    }

    @Test func kadStates() {
        #expect(!NetworkPresentation.kadBadge(.open).isAbnormal)
        #expect(NetworkPresentation.kadBadge(.firewalled).isAbnormal)
        #expect(NetworkPresentation.kadDescription(.firewalled) == "已连接，但外部暂时无法主动连入")
    }

    @Test func bittorrentAndMapping() {
        #expect(NetworkPresentation.bittorrentPort(reachable: nil).text == "未确认")
        #expect(NetworkPresentation.bittorrentPort(reachable: false).isAbnormal)
        #expect(NetworkPresentation.portMapping(succeeded: nil) == nil)
        #expect(NetworkPresentation.portMapping(succeeded: false)?.text == "暂未自动打开端口")
    }
}

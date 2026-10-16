import Foundation
import Testing
@testable import MuleeCore

@Suite struct RouterWANIPv4Tests {
    private let localIP = "10.0.0.2"
    private let mask = "255.255.255.0"
    private let gateway = "10.0.0.1"
    private let location = URL(string: "http://10.0.0.1:1234/description.xml")!
    private let serviceType = "urn:schemas-upnp-org:service:WANIPConnection:1"

    @Test func privateAndSharedRangesIncludeBothBoundaries() {
        // 整数表示范围边界，避免将实际网络地址写入测试。
        for (start, end) in [(UInt32(0x0A000000), UInt32(0x0AFFFFFF)),
                             (0xAC100000, 0xAC1FFFFF), (0xC0A80000, 0xC0A8FFFF),
                             (0x64400000, 0x647FFFFF)] {
            #expect(RouterWANIPv4.status(address: dotted(start)) == .noPublicIPv4)
            #expect(RouterWANIPv4.status(address: dotted(end)) == .noPublicIPv4)
            #expect(RouterWANIPv4.status(address: dotted(start - 1)) != .noPublicIPv4)
            #expect(RouterWANIPv4.status(address: dotted(end + 1)) != .noPublicIPv4)
        }
    }

    @Test(arguments: ["", "10.0.0", "10.0.0.256", "010.0.0.1", "10.0.0.1:80", "::1",
                       "0.0.0.0", "127.0.0.1", "192.0.2.1", "198.51.100.1", "203.0.113.1"])
    func invalidAndReservedStayUnknown(address: String) {
        #expect(RouterWANIPv4.status(address: address) == .unknown)
        #expect(RouterWANIPv4.status(address: nil) == .unknown)
    }

    @Test func ordinaryUnicastAddressesCanBeConfirmed() {
        let statuses = (1..<224).map { first in
            RouterWANIPv4.status(address: dotted(UInt32(first) << 24 | 1))
        }
        #expect(statuses.contains(.publicIPv4))
        #expect(statuses.contains(.noPublicIPv4))
        #expect(statuses.contains(.unknown))
    }

    @Test func ssdpRequiresBoundedSuccessfulResponseAndTrustedLocation() {
        #expect(ssdp("http://10.0.0.1:1234/description.xml") == location)
        for value in ["http://203.0.113.1/x", "http://10.0.0.3/x", "http://10.0.0.1.example.com/x",
                      "http://localhost/x", "http://user@10.0.0.1/x", "file:///description.xml",
                      "http://10.0.0.1/x#fragment", "http://10.0.0.1:0/x", "https://10.0.0.1/x"] {
            #expect(ssdp(value) == nil)
        }
        let good = ssdpData(location.absoluteString)
        #expect(RouterWANIPv4.ssdpLocation(good, localIP: "192.0.2.2", mask: mask, gateway: gateway) == nil)
        #expect(RouterWANIPv4.ssdpLocation(good, localIP: localIP, mask: "255.0.255.0", gateway: gateway) == nil)
        #expect(parseSSDP(Data("HTTP/1.1 500 Error\r\n\r\n".utf8)) == nil)
        #expect(parseSSDP(Data(good.dropLast(4))) == nil)
        #expect(parseSSDP(Data((String(decoding: good, as: UTF8.self) + String(repeating: "x", count: RouterWANIPv4.maximumSSDPBytes)).utf8)) == nil)
        #expect(parseSSDP(ssdpData("http://10.0.0.1/x\r\nLOCATION: http://203.0.113.1/x")) == nil)
        #expect(parseSSDP(ssdpData("http://10.0.0.1/x").replacing("upnp:rootdevice", with: "unknown")) == nil)
    }

    @Test func descriptionRequiresIGDAndLocalControlAndBaseURLs() {
        let services = parseServices(description())
        #expect(services.count == 1)
        #expect(services.first?.controlURL == URL(string: "http://10.0.0.1:1234/control"))
        #expect(services.first?.type == serviceType)
        #expect(parseServices(description(control: "http://203.0.113.1/control")).isEmpty)
        #expect(parseServices(description(control: "//203.0.113.1/control")).isEmpty)
        #expect(parseServices(description(base: "<URLBase>http://203.0.113.1/</URLBase>")).isEmpty)
        #expect(parseServices(description().replacing("InternetGatewayDevice", with: "OtherDevice")).isEmpty)
        #expect(parseServices(description().replacing("WANIPConnection", with: "OtherConnection")).isEmpty)
        #expect(parseServices(description().replacing("</service>", with: "<controlURL>/second</controlURL></service>")).isEmpty)
    }

    @Test func soapRequiresExactResponseAndOneIPv4Address() {
        #expect(parseAddress(soap("10.0.0.1")) == "10.0.0.1")
        #expect(parseAddress(soap("203.0.113.1")) == "203.0.113.1")
        #expect(parseAddress(soap("::1")) == nil)
        #expect(parseAddress(soap("10.0.0.1").replacing("GetExternalIPAddressResponse", with: "Fault")) == nil)
        #expect(parseAddress(soap("10.0.0.1").replacing(serviceType, with: "urn:wrong")) == nil)
        #expect(parseAddress(soap("10.0.0.1").replacing("</NewExternalIPAddress>", with: "</NewExternalIPAddress><NewExternalIPAddress>10.0.0.3</NewExternalIPAddress>")) == nil)
        #expect(parseAddress(soap("10.0.0.1").replacing("</s:Body>", with: "<s:Fault/></s:Body>")) == nil)
    }

    @Test func maliciousOversizeAndMalformedXMLAreRejected() {
        let attacks = [
            "<!DOCTYPE root SYSTEM 'http://203.0.113.1/external'>" + description(),
            "<!DOCTYPE root [<!ENTITY x SYSTEM 'file:///external'>]>" + description(),
            "<!DOCTYPE root [<!ENTITY x 'expanded'>]>" + description(),
            description() + String(repeating: " ", count: RouterWANIPv4.maximumXMLBytes),
            "<root>" + String(repeating: "<device>", count: 40) + String(repeating: "</device>", count: 40) + "</root>",
            "<root>" + String(repeating: "<device/>", count: 1025) + "</root>",
            description().replacing("</root>", with: ""),
            description() + "\0"
        ]
        for attack in attacks { #expect(parseServices(attack).isEmpty) }
        for attack in ["<!DOCTYPE x [<!ENTITY x '10.0.0.1'>]>" + soap("&x;"),
                       soap("10.0.0.1") + String(repeating: " ", count: RouterWANIPv4.maximumXMLBytes)] {
            #expect(parseAddress(attack) == nil)
        }
        #expect(RouterWANIPv4.externalAddress(soap("10.0.0.1").data(using: .utf16)!, serviceType: serviceType) == nil)
    }

    private func dotted(_ ip: UInt32) -> String {
        [24, 16, 8, 0].map { String((ip >> $0) & 255) }.joined(separator: ".")
    }

    private func ssdpData(_ url: String) -> Data {
        Data("HTTP/1.1 200 OK\r\nST: upnp:rootdevice\r\nLOCATION: \(url)\r\n\r\n".utf8)
    }

    private func ssdp(_ url: String) -> URL? {
        parseSSDP(ssdpData(url))
    }

    private func parseSSDP(_ data: Data) -> URL? {
        RouterWANIPv4.ssdpLocation(data, localIP: localIP, mask: mask, gateway: gateway)
    }

    private func parseServices(_ xml: String) -> [RouterWANIPv4.Service] {
        RouterWANIPv4.services(Data(xml.utf8), location: location, localIP: localIP, mask: mask, gateway: gateway)
    }

    private func parseAddress(_ xml: String) -> String? {
        RouterWANIPv4.externalAddress(Data(xml.utf8), serviceType: serviceType)
    }

    private func description(control: String = "/control", base: String = "") -> String {
        """
        <root xmlns="urn:schemas-upnp-org:device-1-0">
          \(base)
          <device>
            <deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType>
            <device><serviceList><service>
              <serviceType>\(serviceType)</serviceType>
              <controlURL>\(control)</controlURL>
            </service></serviceList></device>
          </device>
        </root>
        """
    }

    private func soap(_ address: String) -> String {
        """
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:GetExternalIPAddressResponse xmlns:u="\(serviceType)">
              <NewExternalIPAddress>\(address)</NewExternalIPAddress>
            </u:GetExternalIPAddressResponse>
          </s:Body>
        </s:Envelope>
        """
    }
}

private extension Data {
    func replacing(_ source: String, with replacement: String) -> Data {
        Data(String(decoding: self, as: UTF8.self).replacingOccurrences(of: source, with: replacement).utf8)
    }
}

private extension String {
    func replacing(_ source: String, with replacement: String) -> String {
        replacingOccurrences(of: source, with: replacement)
    }
}

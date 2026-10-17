import Foundation
import Testing
@testable import MuleeCore

struct HTTPProxyTests {
    @Test(arguments: HTTPProxyConfiguration.Mode.allCases)
    func modesMapEverySystemShape(_ mode: HTTPProxyConfiguration.Mode) throws {
        let shapes: [([String: Any], String?, Bool)] = [
            ([:], nil, false),
            (["HTTPEnable": 1, "HTTPProxy": "proxy.example.org", "HTTPPort": 8080], "http://proxy.example.org:8080", false),
            (["HTTPSEnable": 1, "HTTPSProxy": "secure.example.org", "HTTPSPort": 8443,
              "HTTPEnable": 1, "HTTPProxy": "proxy.example.org", "HTTPPort": 8080], "http://secure.example.org:8443", false),
            (["SOCKSEnable": 1, "SOCKSProxy": "proxy.example.org", "SOCKSPort": 1080], nil, true),
            (["ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": "https://example.org/proxy.pac"], nil, true),
            (["ProxyAutoDiscoveryEnable": 1], nil, true),
            (["HTTPEnable": 1, "HTTPProxy": "proxy.example.org", "HTTPPort": 0], nil, false),
            (["HTTPEnable": 0, "HTTPProxy": "proxy.example.org", "HTTPPort": 8080], nil, false)
        ]
        for (dictionary, expectedURL, unsupported) in shapes {
            let system = SystemProxyReader.parse(dictionary)
            let proxy = HTTPProxyConfiguration(mode: mode, manualURL: "http://manual.example.org:8888", system: system, environment: [:])
            switch mode {
            case .system:
                #expect(proxy.url?.absoluteString == expectedURL)
                #expect((proxy.unsupportedReason != nil) == unsupported)
                #expect(proxy.proxyArguments().isEmpty)
            case .off:
                #expect(proxy.url == nil)
                #expect(proxy.unsupportedReason == nil)
                #expect(proxy.proxyArguments() == ["--proxy", ""])
            case .manual:
                #expect(proxy.url?.host == "manual.example.org")
                #expect(proxy.proxyArguments() == ["--proxy", "http://manual.example.org:8888"])
                #expect(proxy.sessionProxyDictionary["HTTPSProxy"] as? String == "manual.example.org")
            }
            #expect(proxy.aria2Options["all-proxy"] == proxy.url?.absoluteString ?? "")
            #expect(proxy.noProxy == ["localhost", "127.0.0.1", "::1"])
        }
    }

    @Test func exceptionsMergeWithEnvironmentAndKeepLocalAddresses() {
        let system = SystemProxyReader.parse(["ExceptionsList": ["*.example.org", "localhost", "192.0.2.5"]])
        let proxy = HTTPProxyConfiguration(system: system, environment: ["no_proxy": "localhost, example.net", "NO_PROXY": "example.net,::1"])
        #expect(proxy.noProxy == ["localhost", "127.0.0.1", "::1", "*.example.org", "192.0.2.5", "example.net"])
        #expect(proxy.aria2Options["no-proxy"] == "localhost,127.0.0.1,::1,.example.org,192.0.2.5,example.net")
        #expect(HTTPProxyConfiguration(mode: .off, system: system, environment: [:]).noProxy.count == 3)
    }

    @Test func credentialsNeverAppearInDescriptionsOrStoredAddress() throws {
        let address = "http://" + "user:password" + "@proxy.example.org:8080"
        let credential = HTTPCredentialStore.Credential(username: "user", password: "password")
        let proxy = HTTPProxyConfiguration(mode: .manual, manualURL: address, credential: credential, environment: [:])
        #expect(proxy.url?.absoluteString == "http://proxy.example.org:8080")
        #expect(!String(reflecting: proxy).contains("password"))
        #expect(!String(reflecting: credential).contains("password"))
        #expect(HTTPProxyConfiguration.redacted("failed: " + address) == "failed: http://***@proxy.example.org:8080")
        #expect(!YtDlpErrorDescriptions.message("network failed: " + address).contains("password"))
        #expect(proxy.aria2Options["all-proxy-passwd"] == "password")
        #expect(proxy.proxyArguments().last == address)
        #expect(proxy.aria2Options["all-proxy"]?.contains("password") == false)
    }

    @Test(arguments: ["", "socks5://proxy.example.org:1080", "https://proxy.example.org:8080", "http://proxy.example.org",
                      "http://proxy.example.org:0", "http://proxy.example.org:65536", "http://proxy.example.org:80/path",
                      "http://proxy.example.org:80?token=private", "http://proxy.example.org:80\n"])
    func rejectsInvalidManualAddresses(_ address: String) {
        let proxy = HTTPProxyConfiguration(mode: .manual, manualURL: address, environment: [:])
        #expect(proxy.url == nil)
        #expect(proxy.unsupportedReason != nil)
        #expect(proxy.sessionProxyDictionary.isEmpty)
    }

    @Test func proxyOptionsReachStartupAndRuntimeConfiguration() throws {
        let root = URL(filePath: "/tmp/http-proxy-tests")
        var configuration = Aria2Configuration(stateDirectory: root, port: 34567, secret: "test", options: .init(downloadDirectory: root))
        configuration.proxy = HTTPProxyConfiguration(mode: .manual, manualURL: "http://proxy.example.org:8080", environment: [:])
        #expect(configuration.runtimeOptions["all-proxy"] == "http://proxy.example.org:8080")
        #expect(try configuration.contents().contains("all-proxy=http://proxy.example.org:8080\n"))
        configuration.proxy = HTTPProxyConfiguration(mode: .off, environment: [:])
        #expect(configuration.runtimeOptions["all-proxy"] == "")
        #expect(configuration.runtimeOptions["all-proxy-passwd"] == "")
    }
}

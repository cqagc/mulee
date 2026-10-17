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

    @Test func onlyAuthenticatedProxySessionsEnableStartupPause() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-session-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var configuration = Aria2Configuration(stateDirectory: root, port: 34567, secret: "test", options: .init(downloadDirectory: root))
        configuration.proxy = HTTPProxyConfiguration(
            mode: .manual, manualURL: "http://proxy.example.org:8080", credential: .init(username: "user", password: "password"), environment: [:]
        )
        #expect(!((try configuration.contents()).contains("pause=true\n")))
        try Data().write(to: configuration.sessionURL)
        #expect((try configuration.contents()).contains("pause=true\n"))
        configuration.proxy = HTTPProxyConfiguration(mode: .manual, manualURL: "http://proxy.example.org:8080", environment: [:])
        #expect(!((try configuration.contents()).contains("pause=true\n")))
        configuration.proxy = HTTPProxyConfiguration(mode: .off, environment: [:])
        #expect(!((try configuration.contents()).contains("pause=true\n")))
    }

    @Test func configurationNeverSerializesProxyCredentials() throws {
        let root = URL(filePath: "/tmp/http-proxy-tests")
        var configuration = Aria2Configuration(stateDirectory: root, port: 34567, secret: "rpc-test", options: .init(downloadDirectory: root))
        configuration.proxy = HTTPProxyConfiguration(
            mode: .manual, manualURL: "http://proxy.example.org:8080",
            credential: .init(username: "proxy-test-account", password: "proxy-test-password"), environment: [:]
        )
        let text = try configuration.contents()
        #expect(!text.contains("proxy-test-account"))
        #expect(!text.contains("proxy-test-password"))
        #expect(!text.contains("all-proxy-user="))
        #expect(!text.contains("all-proxy-passwd="))
        #expect(configuration.runtimeOptions["all-proxy-user"] == "proxy-test-account")
        #expect(configuration.runtimeOptions["all-proxy-passwd"] == "proxy-test-password")
        #expect(text.contains("rpc-secret=rpc-test\n"))
    }

    @Test(arguments: HTTPProxyConfiguration.Mode.allCases)
    func playlistAndFormatProbesUseTheSelectedProxy(_ mode: HTTPProxyConfiguration.Mode) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("http-proxy-probe-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("yt-dlp")
        let script = #"""
        #!/bin/sh
        printf '%s\n' "$@" > "$0.arguments"
        printf '%s\n' '{"formats":[],"entries":[{"id":"Example0001"}]}'
        """#
        try Data(script.utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let proxy = HTTPProxyConfiguration(
            mode: mode, manualURL: "http://proxy.example.org:8080",
            credential: .init(username: "user", password: "password"), environment: [:]
        )
        let playlist = try #require(URL(string: "https://www.youtube.com/playlist?list=ExampleList"))
        let video = try #require(URL(string: "https://www.youtube.com/watch?v=Example0001"))
        for operation in 0..<3 {
            switch operation {
            case 0: _ = try await YtDlpPlaylist.fetch(url: playlist, binary: binary, proxy: proxy)
            case 1: _ = try await YtDlpFormats.fetchMetadata(url: video, site: .youtube, binary: binary, proxy: proxy)
            default: _ = try await YtDlpFormats.fetch(url: video, site: .youtube, binary: binary, proxy: proxy)
            }
            let arguments = try String(contentsOf: root.appendingPathComponent("yt-dlp.arguments"), encoding: .utf8)
                .components(separatedBy: "\n")
            if mode == .system {
                #expect(!arguments.contains("--proxy"))
            } else {
                let index = try #require(arguments.firstIndex(of: "--proxy"))
                try #require(index + 1 < arguments.count)
                let expected = mode == .off ? "" : "http://" + "user:password" + "@proxy.example.org:8080"
                #expect(arguments[index + 1] == expected)
                #expect(arguments.filter { $0 == "--proxy" }.count == 1)
            }
        }
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

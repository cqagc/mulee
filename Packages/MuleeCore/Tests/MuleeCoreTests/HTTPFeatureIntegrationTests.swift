import Foundation
import Synchronization
import Testing
@testable import MuleeCore

@Suite(.serialized, .enabled(if: Aria2IntegrationFixture.binaryAvailable))
struct HTTPFeatureIntegrationTests {
    @Test func authenticationFailureCanRetryWithoutCredentialsInHistory() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let link = try fixture.link("auth.bin")
            let failedID = try await fixture.engine.add(link: link, directory: nil)
            let failed = try await fixture.waitFor(failedID) { $0.status == .failed }
            #expect(HTTPDownloadFailure.requiresCredentials(status: failed.status, message: failed.errorMessage))
            let credential = HTTPCredentialStore.Credential(username: "user", password: "password")
            let context = DownloadRequestContext(headers: ["Authorization": credential.authorization])
            let retried = try await fixture.engine.add(link: link, directory: nil, context: context)
            let completed = try await fixture.waitFor(retried) { $0.status == .completed }
            #expect(completed.receivedBytes == fixture.payload.count)
            #expect(!String(decoding: try JSONEncoder().encode(context), as: UTF8.self).contains(credential.authorization))
        }
    }

    @Test func mirrorValidationAndStreamingOptionsReachRunningAria2() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let link = try fixture.link("slow-original.bin")
            let id = try await fixture.engine.add(link: link, directory: nil, context: .init(), incompleteTaskID: UUID())
            _ = try await fixture.waitFor(id) { $0.status == .downloading }
            let rpc = try fixture.rpc()
            let before: [String: String] = try await rpc.call("aria2.getOption", [.string(id)])
            try await fixture.engine.setStreaming(id, enabled: true)
            let during: [String: String] = try await rpc.call("aria2.getOption", [.string(id)])
            #expect(during["stream-piece-selector"] == "inorder")
            let progress = try await fixture.engine.streamingProgress(id)
            #expect(progress.file?.path.contains(".mulee-incomplete") == true)
            #expect(progress.contiguous <= progress.size)
            try await fixture.engine.setStreaming(id, enabled: false)
            let after: [String: String] = try await rpc.call("aria2.getOption", [.string(id)])
            #expect(after["stream-piece-selector"] == before["stream-piece-selector"])
            guard case .http(let mirror, _, _) = try fixture.link("slow-mirror.bin") else { return }
            let identity = HTTPResourceIdentity(size: Int64(fixture.payload.count), etag: "\"payload-v1\"")
            try await fixture.engine.addMirror(id, url: mirror, original: identity)
            await #expect(throws: HTTPDownloadFailure.resourceChanged) {
                try await fixture.engine.addMirror(id, url: mirror, original: .init(size: Int64(fixture.payload.count) + 1))
            }
            await #expect(throws: HTTPDownloadFailure.resourceChanged) {
                try await fixture.engine.addMirror(id, url: mirror, original: .init(size: Int64(fixture.payload.count), etag: "different"))
            }
            let uris: [Aria2RPCModels.URI] = try await rpc.call("aria2.getUris", [.string(id)])
            #expect(uris.contains { $0.uri == mirror.absoluteString })
            try await fixture.engine.setStreaming(id, enabled: true)
            _ = try await fixture.waitFor(id) { $0.status == .completed }
            try await fixture.engine.setStreaming(id, enabled: false)
        }
    }

    @Test(arguments: [false, true])
    func metalinkFileAndLinkDispatchTheirFileToAria2(_ remote: Bool) async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            guard case .http(let source, _, _) = try fixture.link("payload.bin") else { return }
            let manifest = fixture.root.appendingPathComponent("example.meta4")
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <metalink xmlns="urn:ietf:params:xml:ns:metalink">
              <file name="metalink.bin">
                <size>\(fixture.payload.count)</size>
                <url>\(source.absoluteString)</url>
              </file>
            </metalink>
            """
            try Data(xml.utf8).write(to: manifest)
            let server = try Aria2HTTPServer(payload: Data(xml.utf8))
            do {
                let port = try await server.start()
                let address = remote ? "http://127.0.0.1:\(port)/example.meta4" : manifest.absoluteString
                let link = try #require(LinkParser.parse(address).first)
                let id = try await fixture.engine.add(link: link, directory: fixture.downloads)
                let complete = try await fixture.waitFor(id) { $0.status == .completed }
                let file = try #require(complete.savePath)
                #expect(try Data(contentsOf: file) == fixture.payload)
                await server.stop()
            } catch {
                await server.stop()
                throw error
            }
        }
    }

    @Test func proxyRefreshChangesGlobalOptionsWithoutRestartingEngine() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            let selected = Mutex(HTTPProxyConfiguration(mode: .off, environment: [:]))
            let engine = Aria2Engine(
                stateDirectory: fixture.root.appendingPathComponent("proxy-state"),
                binaryURL: URL(filePath: try #require(ProcessInfo.processInfo.environment["MULEE_ARIA2C"])),
                proxyProvider: { selected.withLock { $0 } }
            )
            do {
                try await engine.start(options: fixture.options)
                selected.withLock { $0 = HTTPProxyConfiguration(mode: .manual, manualURL: "http://proxy.example.org:8080", environment: [:]) }
                try await engine.refreshProxy()
                let text = try String(contentsOf: fixture.root.appendingPathComponent("proxy-state/aria2.conf"), encoding: .utf8)
                #expect(text.contains("all-proxy=http://proxy.example.org:8080\n"))
                let values = Dictionary(uniqueKeysWithValues: text.split(separator: "\n").compactMap { line -> (String, String)? in
                    let pair = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                    guard pair.count == 2 else { return nil }
                    return (String(pair[0]), String(pair[1]))
                })
                let rpc = try Aria2RPCClient(
                    port: #require(values["rpc-listen-port"].flatMap(UInt16.init)), secret: #require(values["rpc-secret"])
                )
                let global: [String: String] = try await rpc.call("aria2.getGlobalOption")
                #expect(global["all-proxy"].flatMap(HTTPProxyConfiguration.manualURL)?.absoluteString == "http://proxy.example.org:8080")
                selected.withLock { $0 = HTTPProxyConfiguration(mode: .off, environment: [:]) }
                try await engine.refreshProxy()
                #expect(try String(contentsOf: fixture.root.appendingPathComponent("proxy-state/aria2.conf"), encoding: .utf8).contains("all-proxy=\n"))
                let direct: [String: String] = try await rpc.call("aria2.getGlobalOption")
                #expect(direct["all-proxy"] == "")
                await engine.stop()
            } catch {
                await engine.stop()
                throw error
            }
        }
    }
}

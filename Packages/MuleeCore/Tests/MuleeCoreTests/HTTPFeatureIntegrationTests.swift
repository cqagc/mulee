import Foundation
import Synchronization
import Testing
@testable import MuleeCore

@Suite(.serialized, .enabled(if: Aria2IntegrationFixture.binaryAvailable))
struct HTTPFeatureIntegrationTests {
    @Test func authenticatedProxySessionWaitsForPerTaskCredentialsAndAppAdmission() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            let credential = HTTPCredentialStore.Credential(username: "proxy-account", password: "proxy-password")
            let proxy = try Aria2HTTPServer(payload: Data(repeating: 7, count: 65_536))
            await proxy.requireProxyAuthorization(credential.authorization)
            let port = try await proxy.start()
            let proxyURL = "http://127.0.0.1:\(port)"
            let engine = Aria2Engine(
                stateDirectory: fixture.state,
                binaryURL: URL(filePath: try #require(ProcessInfo.processInfo.environment["MULEE_ARIA2C"])),
                proxyProvider: { HTTPProxyConfiguration(mode: .manual, manualURL: proxyURL, credential: credential, environment: [:]) }
            )
            do {
                try FileManager.default.createDirectory(at: fixture.state, withIntermediateDirectories: true)
                let session = """
                http://origin.example.org/slow-resumed.bin
                 gid=0000000000000001
                 dir=\(fixture.downloads.path)
                 out=resumed.bin
                http://origin.example.org/slow-paused.bin
                 gid=0000000000000002
                 dir=\(fixture.downloads.path)
                 out=paused.bin
                 pause=true
                """
                try Data((session + "\n").utf8).write(to: fixture.state.appendingPathComponent("aria2.session"))
                try await engine.start(options: fixture.options)
                #expect(await proxy.receivedHeaders.isEmpty)
                let restored = try await engine.snapshots()
                #expect(restored.count == 2)
                #expect(restored.allSatisfy { $0.status == .paused })
                #expect(await engine.takeProxyRestoredTaskIDs() == ["0000000000000001", "0000000000000002"])
                let rpc = try fixture.rpc()
                for id in ["0000000000000001", "0000000000000002"] {
                    let options: [String: String] = try await rpc.call("aria2.getOption", [.string(id)])
                    #expect(options["all-proxy-user"] == credential.username)
                    #expect(options["all-proxy-passwd"] == credential.password)
                    #expect(options["all-proxy"].flatMap(HTTPProxyConfiguration.manualURL)?.absoluteString == proxyURL)
                }
                let conf = try String(contentsOf: fixture.state.appendingPathComponent("aria2.conf"), encoding: .utf8)
                #expect(!conf.contains(credential.password))
                try await engine.resume("0000000000000001")
                let deadline = ContinuousClock.now.advanced(by: .seconds(10))
                var complete = false
                while ContinuousClock.now < deadline {
                    let snapshots = try await engine.snapshots()
                    if snapshots.contains(where: { $0.engineTaskID == "0000000000000001" && $0.status == .completed }) {
                        complete = true
                        break
                    }
                    try await Task.sleep(for: .milliseconds(25))
                }
                #expect(complete)
                #expect(try await engine.snapshots().first { $0.engineTaskID == "0000000000000002" }?.status == .paused)
                #expect(await proxy.proxyAuthenticationFailures == 0)
                #expect(await proxy.receivedHeaders.allSatisfy { $0["proxy-authorization"] == credential.authorization })
                let freshURL = try #require(URL(string: "http://origin.example.org/new.bin"))
                let fresh = try await engine.add(link: .http(url: freshURL, decodedFromThunder: false, original: freshURL.absoluteString), directory: fixture.downloads)
                let status: Aria2RPCModels.Status = try await rpc.call("aria2.tellStatus", [.string(fresh)])
                #expect(status.status != "paused")
                await engine.stop()
                await proxy.stop()
            } catch {
                await engine.stop()
                await proxy.stop()
                throw error
            }
        }
    }

    @Test func credentialedEmptyResourceAcceptsUnsatisfiedZeroRange() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            let server = try Aria2HTTPServer(payload: Data())
            do {
                let port = try await server.start()
                let url = try #require(URL(string: "http://127.0.0.1:\(port)/empty.bin"))
                let context = DownloadRequestContext(headers: ["Authorization": "Basic example-token"], cookie: "sid=example-cookie")
                let identity = try await HTTPResourceProbe.inspect(url, context: context)
                #expect(identity.size == 0)
                let prepared = try await HTTPResourceProbe.prepareDownload(url, context: context)
                #expect(prepared.url == url)
                #expect(prepared.context.headers["Authorization"] == "Basic example-token")
                try await fixture.engine.start(options: fixture.options)
                let id = try await fixture.engine.add(
                    link: .http(url: url, decodedFromThunder: false, original: url.absoluteString), directory: fixture.downloads, context: context
                )
                let complete = try await fixture.waitFor(id) { $0.status == .completed }
                #expect(complete.receivedBytes == 0)
                #expect(await server.receivedHeaders.contains { $0["range"] == "bytes=0-0" })
                await server.stop()
            } catch {
                await server.stop()
                throw error
            }
        }
    }

    @Test func GETOnlyCrossHostRedirectNeverForwardsCredentialsToAria2() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            let destination = try Aria2HTTPServer(payload: fixture.payload)
            do {
                let port = try await destination.start()
                let target = try #require(URL(string: "http://localhost:\(port)/payload.bin"))
                await fixture.server.setRedirect(target, onlyGET: true)
                let link = try fixture.link("head-success.bin")
                guard case .http(let original, _, _) = link else { return }
                let head = try await HTTPResourceProbe.inspect(original)
                #expect(head.size == Int64(fixture.payload.count))
                #expect(await destination.receivedHeaders.isEmpty)
                try await fixture.engine.start(options: fixture.options)
                let context = DownloadRequestContext(headers: ["Authorization": "Basic example-token"], cookie: "sid=example-cookie")
                let id = try await fixture.engine.add(link: link, directory: nil, context: context, paused: true)
                let rpc = try fixture.rpc()
                let uris: [Aria2RPCModels.URI] = try await rpc.call("aria2.getUris", [.string(id)])
                #expect(uris.first?.uri == target.absoluteString)
                try await fixture.engine.resume(id)
                _ = try await fixture.waitFor(id) { $0.status == .completed }
                let sourceRequests = await fixture.server.receivedHeaders
                #expect(sourceRequests.contains {
                    $0["range"] == "bytes=0-0" && $0["authorization"] == "Basic example-token" && $0["cookie"] == "sid=example-cookie"
                })
                let received = await destination.receivedHeaders
                #expect(!received.isEmpty)
                #expect(received.allSatisfy { $0["authorization"] == nil && $0["cookie"] == nil })
                await destination.stop()
            } catch {
                await destination.stop()
                throw error
            }
        }
    }

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
            let paused = try await fixture.engine.add(
                link: fixture.link("slow-session.bin"), directory: nil,
                context: DownloadRequestContext(headers: ["Authorization": credential.authorization], cookie: "sid=example-cookie"), paused: true
            )
            let rpc = try fixture.rpc()
            let session = fixture.state.appendingPathComponent("aria2.session")
            for _ in 0..<2 {
                let _: String = try await rpc.call("aria2.saveSession")
                try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: session.path)
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while ContinuousClock.now < deadline {
                    let attributes = try FileManager.default.attributesOfItem(atPath: session.path)
                    if (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 { break }
                    try await Task.sleep(for: .milliseconds(20))
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: session.path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
            }
            let text = try String(contentsOf: session, encoding: .utf8)
            #expect(text.contains(paused))
            #expect(text.contains(credential.authorization))
            let directory = try FileManager.default.attributesOfItem(atPath: fixture.state.path)
            #expect((directory[.posixPermissions] as? NSNumber)?.intValue == 0o700)
            await fixture.engine.stop()
            let attributes = try FileManager.default.attributesOfItem(atPath: session.path)
            #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
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
            let credential = HTTPCredentialStore.Credential(username: "proxy-test-account", password: "proxy-test-password")
            let selected = Mutex(HTTPProxyConfiguration(
                mode: .manual, manualURL: "http://proxy.example.org:8080", credential: credential, environment: [:]
            ))
            let engine = Aria2Engine(
                stateDirectory: fixture.root.appendingPathComponent("proxy-state"),
                binaryURL: URL(filePath: try #require(ProcessInfo.processInfo.environment["MULEE_ARIA2C"])),
                proxyProvider: { selected.withLock { $0 } }
            )
            do {
                try await engine.start(options: fixture.options)
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
                #expect(global["all-proxy-user"] == credential.username)
                #expect(global["all-proxy-passwd"] == credential.password)
                #expect(!text.contains(credential.username))
                #expect(!text.contains(credential.password))
                let changedCredential = HTTPCredentialStore.Credential(username: "updated-account", password: "updated-password")
                selected.withLock { $0 = HTTPProxyConfiguration(
                    mode: .manual, manualURL: "http://proxy.example.org:8080", credential: changedCredential, environment: [:]
                ) }
                try await engine.refreshProxy()
                let changed: [String: String] = try await rpc.call("aria2.getGlobalOption")
                #expect(changed["all-proxy-user"] == changedCredential.username)
                #expect(changed["all-proxy-passwd"] == changedCredential.password)
                let updated = try String(contentsOf: fixture.root.appendingPathComponent("proxy-state/aria2.conf"), encoding: .utf8)
                #expect(!updated.contains(changedCredential.username))
                #expect(!updated.contains(changedCredential.password))
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

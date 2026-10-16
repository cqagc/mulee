import CryptoKit
import Darwin
import Foundation
import Testing
@testable import MuleeCore

@Suite(.serialized, .enabled(if: Aria2IntegrationFixture.binaryAvailable))
struct Aria2IntegrationTests {
    @Test("真实请求携带来源、UA、Cookie、建议文件名和校验值")
    func browserContextAndChecksum() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let digest = SHA256.hash(data: fixture.payload).map { String(format: "%02x", $0) }.joined()
            let checksum = try #require(DownloadChecksum(algorithm: .sha256, digest: digest))
            let id = try await fixture.engine.add(
                link: fixture.link("payload.bin"), directory: nil,
                context: DownloadRequestContext(
                    referer: URL(string: "https://example.org/page"), userAgent: "Browser/1",
                    suggestedFilename: "suggested.bin", headers: ["X-Download": "context"], cookie: "session=test-only"
                ), checksum: checksum
            )
            let completed = try await fixture.waitFor(id) { $0.status == .completed }
            #expect(completed.savePath?.lastPathComponent == "suggested.bin")
            let headers = await fixture.server.receivedHeaders
            #expect(headers.contains { $0["referer"] == "https://example.org/page" && $0["user-agent"] == "Browser/1"
                && $0["cookie"] == "session=test-only" && $0["x-download"] == "context" })
        }
    }

    @Test("真实 HEAD 预检识别大小、ETag、网页与失效链接")
    func resourceProbe() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            guard case .http(let url, _, _) = try fixture.link("payload.bin") else { return }
            let identity = try await HTTPResourceProbe.inspect(url)
            #expect(identity.size == Int64(fixture.payload.count))
            #expect(identity.etag == "\"payload-v1\"")
            let page = url.deletingLastPathComponent().appendingPathComponent("page.bin")
            await #expect(throws: HTTPDownloadFailure.webPage) { try await HTTPResourceProbe.inspect(page) }
            let expired = url.deletingLastPathComponent().appendingPathComponent("status-403.bin")
            await #expect(throws: HTTPDownloadFailure.expiredLink) { try await HTTPResourceProbe.inspect(expired) }
        }
    }

    @Test("换链通过 changeUri 保留路径与分块并继续下载")
    func changeURIResumesSameFile() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let id = try await fixture.engine.add(link: fixture.link("slow-original.bin"), directory: nil)
            _ = try await fixture.waitFor(id) { $0.receivedBytes > 131_072 }
            try await fixture.engine.pause(id)
            let paused = try await fixture.waitFor(id) { $0.status == .paused }
            guard case .http(let url, _, _) = try fixture.link("replacement.bin") else { return }
            let replaced = try await fixture.engine.replaceURI(id, with: url, context: .init(), checksum: nil)
            #expect(replaced == id)
            try await fixture.engine.resume(replaced)
            let completed = try await fixture.waitFor(replaced) { $0.status == .completed }
            #expect(completed.savePath == paused.savePath)
            let path = try #require(completed.savePath)
            #expect(SHA256.hash(data: try Data(contentsOf: path)) == SHA256.hash(data: fixture.payload))
            #expect(await fixture.server.rangeRequests > 0)
        }
    }

    @Test("停态任务换链重建 GID 并从原控制文件续传")
    func stoppedTaskReplacement() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let id = try await fixture.engine.add(link: fixture.link("slow-stopped.bin"), directory: nil)
            let active = try await fixture.waitFor(id) { $0.receivedBytes > 131_072 }
            let rpc = try fixture.rpc()
            let _: String = try await rpc.call("aria2.forceRemove", [.string(id)])
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            var status: Aria2RPCModels.Status = try await rpc.call("aria2.tellStatus", [.string(id)])
            while status.status != "removed", ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
                status = try await rpc.call("aria2.tellStatus", [.string(id)])
            }
            #expect(status.status == "removed")
            guard case .http(let url, _, _) = try fixture.link("replacement.bin") else { return }
            let newID = try await fixture.engine.replaceURI(id, with: url, context: .init(), checksum: nil)
            #expect(newID != id)
            try await fixture.engine.resume(newID)
            let completed = try await fixture.waitFor(newID) { $0.status == .completed }
            #expect(completed.savePath == active.savePath)
            #expect(await fixture.server.rangeRequests > 0)
        }
    }

    @Test("aria2 校验失败以明确错误结束")
    func checksumMismatch() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let checksum = try #require(DownloadChecksum.parse(String(repeating: "0", count: 64)))
            let id = try await fixture.engine.add(link: fixture.link("payload.bin"), directory: nil, context: .init(), checksum: checksum)
            let failed = try await fixture.waitFor(id) { $0.status == .failed }
            #expect(failed.errorMessage?.contains("校验值不一致") == true)
        }
    }

    @Test("带 Cookie 的会话及周期性重建会话始终为 0600")
    func cookieSessionPermissions() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let id = try await fixture.engine.add(
                link: fixture.link("slow-cookie.bin"), directory: nil,
                context: DownloadRequestContext(cookie: "session=test-only"), paused: true
            )
            let rpc = try fixture.rpc()
            for _ in 0..<2 {
                let _: String = try await rpc.call("aria2.saveSession")
                let file = fixture.state.appendingPathComponent("aria2.session")
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
                #expect(try String(contentsOf: file, encoding: .utf8).contains("Cookie: session=test-only"))
            }
            #expect(try await fixture.engine.snapshots().contains { $0.engineTaskID == id })
        }
    }

    @Test("清除 HTTP 校验值保留暂停状态且不再执行旧校验")
    func clearsChecksum() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let checksum = try #require(DownloadChecksum.parse(String(repeating: "0", count: 64)))
            let id = try await fixture.engine.add(
                link: fixture.link("payload.bin"), directory: nil, context: .init(), checksum: checksum, paused: true
            )
            let updatedID = try await fixture.engine.setChecksum(id, checksum: nil)
            #expect(updatedID != id)
            _ = try await fixture.waitFor(updatedID) { $0.status == .paused }
            try await fixture.engine.resume(updatedID)
            _ = try await fixture.waitFor(updatedID) { $0.status == .completed }
        }
    }

    @Test("真实下载 SHA256 一致，目录覆盖及完成文件移入废纸篓")
    func downloadAndTrash() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            try await fixture.engine.start(options: fixture.options)
            #expect(try Aria2IntegrationFixture.childProcessIDs().count == 1)
            let directory = fixture.root.appendingPathComponent("override")
            let id = try await fixture.engine.add(link: fixture.link("payload.bin"), directory: directory)
            let completed = try await fixture.waitFor(id) { $0.status == .completed }
            let path = try #require(completed.savePath)
            #expect(path.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL)
            #expect(completed.totalBytes == Int64(fixture.payload.count))
            #expect(SHA256.hash(data: try Data(contentsOf: path)) == SHA256.hash(data: fixture.payload))
            try await fixture.engine.remove(id, deleteFiles: true)
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(try await fixture.engine.snapshots().isEmpty)
        }
    }

    @Test("暂停幂等、继续后完成且 Range 内容校验通过")
    func pauseAndResume() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let id = try await fixture.engine.add(link: fixture.link("slow-resume.bin"), directory: nil)
            _ = try await fixture.waitFor(id) { $0.receivedBytes > 131_072 }
            try await fixture.engine.pause(id)
            let paused = try await fixture.waitFor(id) { $0.status == .paused }
            try await fixture.engine.pause(id)
            try await Task.sleep(for: .milliseconds(150))
            let stable = try #require(try await fixture.engine.snapshots().first { $0.engineTaskID == id })
            #expect(stable.receivedBytes == paused.receivedBytes)
            try await fixture.engine.resume(id)
            let completed = try await fixture.waitFor(id) { $0.status == .completed }
            let path = try #require(completed.savePath)
            #expect(SHA256.hash(data: try Data(contentsOf: path)) == SHA256.hash(data: fixture.payload))
            #expect(await fixture.server.rangeRequests > 0)
        }
    }

    @Test("活动任务移除并回收下载文件和 aria2 控制文件")
    func removeActive() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let id = try await fixture.engine.add(link: fixture.link("slow-delete.bin"), directory: nil)
            let active = try await fixture.waitFor(id) { $0.receivedBytes > 65_536 }
            let path = try #require(active.savePath)
            #expect(FileManager.default.fileExists(atPath: path.path))
            #expect(FileManager.default.fileExists(atPath: path.path + ".aria2"))
            try await fixture.engine.remove(id, deleteFiles: true)
            #expect(!FileManager.default.fileExists(atPath: path.path))
            #expect(!FileManager.default.fileExists(atPath: path.path + ".aria2"))
            #expect(try await fixture.engine.snapshots().isEmpty)
        }
    }

    @Test("暂停任务在 stop/start 后从会话恢复并下载完成")
    func restoreSession() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let id = try await fixture.engine.add(link: fixture.link("slow-session.bin"), directory: nil)
            _ = try await fixture.waitFor(id) { $0.receivedBytes > 2_400_000 }
            try await fixture.engine.pause(id)
            let paused = try await fixture.waitFor(id) { $0.status == .paused }
            await fixture.engine.stop()
            #expect(try Aria2IntegrationFixture.childProcessIDs().isEmpty)
            await #expect(throws: EngineError.notRunning) { try await fixture.engine.snapshots() }
            let session = try String(contentsOf: fixture.state.appendingPathComponent("aria2.session"), encoding: .utf8)
            #expect(session.contains("gid=\(id)"))
            try await fixture.engine.start(options: fixture.options)
            let restored = try await fixture.waitFor(id) { $0.status == .paused }
            // aria2 loads file metadata and the piece bitmap only when the task resumes.
            #expect(restored.name == paused.name)
            #expect(restored.sourceURL == paused.sourceURL)
            let savedPath = try #require(paused.savePath)
            #expect(FileManager.default.fileExists(atPath: savedPath.path))
            #expect(FileManager.default.fileExists(atPath: savedPath.path + ".aria2"))
            try await fixture.engine.resume(id)
            let completed = try await fixture.waitFor(id) { $0.status == .completed }
            let path = try #require(completed.savePath)
            #expect(path == savedPath)
            #expect(SHA256.hash(data: try Data(contentsOf: path)) == SHA256.hash(data: fixture.payload))
        }
    }

    @Test("不存在的 URL 显示中文失败信息，RPC 错误按契约返回")
    func missingURL() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let id = try await fixture.engine.add(link: fixture.link("missing.bin"), directory: nil)
            let failed = try await fixture.waitFor(id) { $0.status == .failed }
            // 文案随系统语言变化，期望值用同一个函数生成。
            #expect(failed.errorMessage == Aria2ErrorDescriptions.message(for: "3"))
            await #expect(throws: EngineError.unsupportedLink) {
                try await fixture.engine.add(
                    link: .magnet(infoHash: "abc", displayName: nil, original: "magnet:?abc"), directory: nil
                )
            }
            do {
                try await fixture.engine.resume("0000000000000000")
                Issue.record("不存在的 GID 应抛 RPC 错误")
            } catch let error as EngineError {
                guard case .rpc(let code, _) = error else { throw error }
                #expect(code == 1)
            }
        }
    }

    @Test("设置下发自动重启并回读磁盘缓存，保留暂停任务")
    func runtimeOptions() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let paused = try await fixture.engine.addQueued(link: fixture.link("cache-paused.bin"), directory: nil)
            var options = fixture.options
            options.downloadDirectory = fixture.root.appendingPathComponent("changed")
            options.maxConcurrentDownloads = 3
            options.connectionsPerServer = 30
            options.downloadLimit = 1_234_567
            options.uploadLimit = 23_456
            options.diskCacheMegabytes = 12
            try await fixture.engine.apply(options: options)
            let rpc = try fixture.rpc()
            #expect(try await fixture.engine.snapshots().first { $0.engineTaskID == paused }?.status == .paused)
            let globals: [String: String] = try await rpc.call("aria2.getGlobalOption")
            let expected = [
                "dir": options.downloadDirectory.path,
                "max-concurrent-downloads": "3",
                "max-connection-per-server": "16",
                "split": "16",
                "max-overall-download-limit": "1234567"
            ]
            for (key, value) in expected { #expect(globals[key] == value, "\(key) 应即时生效") }
            #expect(globals["max-overall-upload-limit"] == nil || globals["max-overall-upload-limit"] == "0")
            #expect(globals["disk-cache"] == "12582912")
            // Unsupported global keys can return OK while being ignored: verify by readback.
            let _: String = try await rpc.call("aria2.changeGlobalOption", [
                .object(["disk-cache": .string("16M")])
            ])
            let afterCacheChange: [String: String] = try await rpc.call("aria2.getGlobalOption")
            #expect(afterCacheChange["disk-cache"] == "12582912")
            let configuration = try fixture.configurationValues()
            for (key, value) in expected { #expect(configuration[key] == value) }
            #expect(configuration["disk-cache"] == "12M")
            let id = try await fixture.engine.add(link: fixture.link("new-options.bin"), directory: nil)
            let taskOptions: [String: String] = try await rpc.call("aria2.getOption", [.string(id)])
            #expect(taskOptions["dir"] == options.downloadDirectory.path)
            #expect(taskOptions["max-connection-per-server"] == "16")
            #expect(taskOptions["split"] == "16")
            await fixture.engine.stop()
            try await fixture.engine.start(options: options)
            let restarted: [String: String] = try await fixture.rpc().call("aria2.getGlobalOption")
            #expect(restarted["disk-cache"] == "12582912")
        }
    }

    @Test("意外进程退出后拒绝调用且能再次启动")
    func unexpectedExit() async throws {
        try await Aria2IntegrationFixture.withFixture { fixture in
            try await fixture.engine.start(options: fixture.options)
            let pid = try #require(try Aria2IntegrationFixture.childProcessIDs().first)
            #expect(kill(pid, SIGKILL) == 0)
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while try !Aria2IntegrationFixture.childProcessIDs().isEmpty {
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(25))
            }
            await #expect(throws: EngineError.notRunning) { try await fixture.engine.snapshots() }
            try await fixture.engine.start(options: fixture.options)
            #expect(try Aria2IntegrationFixture.childProcessIDs().count == 1)
            #expect(try await fixture.engine.snapshots().isEmpty)
        }
    }
}

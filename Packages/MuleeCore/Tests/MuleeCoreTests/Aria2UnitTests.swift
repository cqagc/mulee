import Foundation
import Testing
@testable import MuleeCore

struct Aria2UnitTests {
    @Test func unsafeStateDirectoryIsRejectedAndPermissionsAreRepaired() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let state = root.appendingPathComponent("state")
        let target = root.appendingPathComponent("target")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: state, withDestinationURL: target)
        let configuration = Aria2Configuration(
            stateDirectory: state, port: 34567, secret: "test", options: EngineOptions(downloadDirectory: root)
        )
        #expect(throws: (any Error).self) { try configuration.write() }
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("aria2.conf").path))
        try FileManager.default.removeItem(at: state)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: state.path)
        try configuration.write()
        let attributes = try FileManager.default.attributesOfItem(atPath: state.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test("手写 JSON 状态映射", arguments: [
        ("active", TaskStatus.downloading), ("waiting", .queued), ("paused", .paused),
        ("complete", .completed), ("error", .failed)
    ])
    func statuses(_ raw: String, _ expected: TaskStatus) throws {
        let json = """
        {"gid":"1234","status":"\(raw)","totalLength":"4096","completedLength":"1024",
         "downloadSpeed":"128","uploadSpeed":"8","connections":"2","errorCode":"3",
         "files":[{"path":"/tmp/downloads/资料.zip","uris":[{"uri":"https://example.com/a.zip"}]}]}
        """
        let status = try JSONDecoder().decode(Aria2RPCModels.Status.self, from: Data(json.utf8))
        let snapshot = try #require(Aria2StatusMapper.snapshot(status))
        #expect(snapshot.status == expected)
        #expect(snapshot.name == "资料.zip")
        #expect(snapshot.totalBytes == 4096)
        #expect(snapshot.receivedBytes == 1024)
        #expect(snapshot.downloadRate == 128)
        #expect(snapshot.uploadRate == 8)
        #expect(snapshot.connections == 2)
        let missingResource = String(localized: "资源不存在", bundle: .module)
        let code = 3
        let expectedError = String(localized: "\(missingResource)（aria2 错误码 \(code)）", bundle: .module)
        #expect(snapshot.errorMessage == (raw == "error" ? expectedError : nil))
    }

    @Test("未知名称从 URL 推断且长度零为 nil")
    func names() throws {
        let json = """
        {"gid":"abc","status":"waiting","totalLength":"0",
         "files":[{"path":"","uris":[{"uri":"https://example.com/%E8%B5%84%E6%96%99%20a.zip"}]}]}
        """
        let status = try JSONDecoder().decode(Aria2RPCModels.Status.self, from: Data(json.utf8))
        let snapshot = try #require(Aria2StatusMapper.snapshot(status))
        #expect(snapshot.name == "资料 a.zip")
        #expect(snapshot.savePath == nil)
        #expect(snapshot.totalBytes == nil)
        let removed = Data(#"{"gid":"abc","status":"removed"}"#.utf8)
        #expect(Aria2StatusMapper.snapshot(try JSONDecoder().decode(Aria2RPCModels.Status.self, from: removed)) == nil)
    }

    @Test("常见错误都有中文说明", arguments: [
        ("3", "资源不存在"), ("6", "网络错误"), ("9", "磁盘空间不足"),
        ("13", "文件已存在"), ("16", "文件创建失败"), ("19", "域名解析失败"),
        ("22", "服务器响应异常"), ("24", "需要登录认证"), ("99", "下载出错")
    ])
    func errors(_ code: String, _ description: String) throws {
        let number = try #require(Int(code))
        let localized = String(localized: String.LocalizationValue(description), bundle: .module)
        #expect(Aria2ErrorDescriptions.message(for: code) == String(localized: "\(localized)（aria2 错误码 \(number)）", bundle: .module))
    }

    @Test("配置保护密钥、限制连接数并只在存在时读取会话")
    func configuration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Aria2-unit-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        let secret = Aria2Configuration.makeSecret()
        #expect(secret.count == 64)
        #expect(secret.allSatisfy { $0.isHexDigit })
        #expect(secret != Aria2Configuration.makeSecret())
        let configuration = Aria2Configuration(
            stateDirectory: root, port: 34567, secret: secret,
            options: EngineOptions(downloadDirectory: root, connectionsPerServer: 100)
        )
        try configuration.write()
        let text = try String(contentsOf: configuration.fileURL, encoding: .utf8)
        #expect(configuration.arguments == ["--conf-path=\(configuration.fileURL.path)"])
        #expect(!configuration.arguments.joined().contains(secret))
        #expect(text.contains("rpc-secret=\(secret)\n"))
        #expect(text.contains("max-connection-per-server=16\n"))
        #expect(text.contains("split=16\n"))
        #expect(text.contains("file-allocation=none\n"))
        #expect(text.contains("rpc-listen-all=false\n"))
        #expect(text.contains("stop-with-process=\(ProcessInfo.processInfo.processIdentifier)\n"))
        #expect(!text.contains("input-file="))
        #expect(text.contains("check-certificate=true\n"))
        for option in ["ca-certificate", "follow-torrent", "enable-dht", "bt-enable-lpd", "max-overall-upload-limit"] {
            #expect(!text.contains("\(option)="))
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: configuration.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        try Data().write(to: configuration.sessionURL)
        try configuration.write()
        #expect(try String(contentsOf: configuration.fileURL, encoding: .utf8).contains("input-file="))
        #expect(Aria2RPCClient.sessionConfiguration().connectionProxyDictionary?.isEmpty == true)
        var invalid = configuration
        invalid.options.downloadDirectory = URL(fileURLWithPath: "/tmp/name\nrpc-listen-all=true")
        #expect(throws: EngineError.self) { try invalid.contents() }
    }

    @Test("删除路径限制到任务目录，阻止穿越、同前缀目录及符号链接")
    func safePaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Aria2-paths-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        let downloads = root.appendingPathComponent("downloads")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let symlink = downloads.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        #expect(Aria2FileSafety.isInside(downloads.appendingPathComponent("file.bin"), directory: downloads))
        #expect(!Aria2FileSafety.isInside(downloads, directory: downloads))
        #expect(!Aria2FileSafety.isInside(downloads.appendingPathComponent("../outside/a"), directory: downloads))
        #expect(!Aria2FileSafety.isInside(root.appendingPathComponent("downloads-other/a"), directory: downloads))
        #expect(!Aria2FileSafety.isInside(symlink.appendingPathComponent("a"), directory: downloads))
        let protected = outside.appendingPathComponent("keep.bin")
        try Data([1, 2, 3]).write(to: protected)
        let json = """
        {"gid":"abc","status":"complete","dir":"\(downloads.path)",
         "files":[{"path":"\(protected.path)"},{"path":"\(symlink.path)/keep.bin"}]}
        """
        let status = try JSONDecoder().decode(Aria2RPCModels.Status.self, from: Data(json.utf8))
        try Aria2FileSafety.trashFiles(for: status)
        #expect(FileManager.default.fileExists(atPath: protected.path))
    }

    @Test("二进制按显式路径、App Helpers、环境变量顺序查找")
    func binaryLookup() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Aria2-binary-\(UUID())")
        defer {
            do { try FileManager.default.removeItem(at: root) } catch { Issue.record(error) }
        }
        let bundle = root.appendingPathComponent("Mulee.app")
        let helper = bundle.appendingPathComponent("Contents/Helpers/aria2c")
        try FileManager.default.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true)
        let explicit = root.appendingPathComponent("explicit-aria2c")
        let environmentBinary = root.appendingPathComponent("environment-aria2c")
        for url in [explicit, helper, environmentBinary] {
            #expect(FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o700]))
        }
        let environment = ["MULEE_ARIA2C": environmentBinary.path]
        #expect(try Aria2BinaryLocator.locate(explicitURL: explicit, bundleURL: bundle, environment: environment) == explicit)
        #expect(try Aria2BinaryLocator.locate(explicitURL: nil, bundleURL: bundle, environment: environment) == helper)
        try FileManager.default.removeItem(at: helper)
        #expect(try Aria2BinaryLocator.locate(explicitURL: nil, bundleURL: bundle, environment: environment) == environmentBinary)
        #expect(throws: EngineError.binaryNotFound) {
            try Aria2BinaryLocator.locate(explicitURL: nil, bundleURL: bundle, environment: [:])
        }
    }

    @Test("URL 名称只解码一次且空名称有默认值", arguments: [
        ("https://example.com/%2520.zip", "%20.zip"),
        ("https://example.com/", "下载文件")
    ])
    func nameDecoding(_ uri: String, _ name: String) throws {
        let json = """
        {"gid":"abc","status":"waiting","files":[{"path":"","uris":[{"uri":"\(uri)"}]}]}
        """
        let status = try JSONDecoder().decode(Aria2RPCModels.Status.self, from: Data(json.utf8))
        #expect(Aria2StatusMapper.snapshot(status)?.name == (name == "下载文件" ? String(localized: "下载文件", bundle: .module) : name))
    }

    @Test("引擎启动前所有业务操作抛 notRunning")
    func notRunning() async throws {
        let engine = Aria2Engine(stateDirectory: URL(fileURLWithPath: "/unused"))
        let url = try #require(URL(string: "https://example.com/a"))
        await #expect(throws: EngineError.notRunning) { try await engine.snapshots() }
        await #expect(throws: EngineError.notRunning) { try await engine.pause("gid") }
        await #expect(throws: EngineError.notRunning) { try await engine.resume("gid") }
        await #expect(throws: EngineError.notRunning) { try await engine.remove("gid", deleteFiles: false) }
        await #expect(throws: EngineError.notRunning) {
            try await engine.add(link: .http(url: url, decodedFromThunder: false, original: url.absoluteString), directory: nil)
        }
        await #expect(throws: EngineError.notRunning) {
            try await engine.apply(options: EngineOptions(downloadDirectory: url))
        }
        await engine.stop()
    }
}

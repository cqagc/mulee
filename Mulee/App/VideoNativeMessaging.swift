import Darwin
import Foundation
import MuleeCore

/// Chrome 以扩展 origin 启动 App 可执行文件；此模式在创建 UI 前退出。
nonisolated enum VideoNativeMessaging {
    static let host = "com.cqagc.mulee.video_login"
    // 与 Chrome manifest 的公开 key 对应；不是秘密或授权令牌。
    static let extensionID = "oibbkfbekjeedglnamajelikapoimdcj"
    static let origin = "chrome-extension://" + extensionID + "/"

    static func isNativeInvocation(_ arguments: [String]) -> Bool {
        arguments.dropFirst().contains { $0.hasPrefix("chrome-extension://") }
    }

    static func acceptsOrigin(_ arguments: [String]) -> Bool {
        arguments.count == 2 && arguments[1] == origin
    }

    static func readRequest(from input: FileHandle) throws -> VideoCookieRequest {
        try VideoCookieRequest.parse(readPayload(from: input))
    }

    static func readPayload(from input: FileHandle) throws -> Data {
        let header = try readExactly(4, from: input)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length <= VideoCookieRequest.maximumBytes else { throw EngineError.unsupportedLink }
        return try readExactly(Int(length), from: input)
    }

    static func readExactly(_ count: Int, from input: FileHandle) throws -> Data {
        var data = Data()
        while data.count < count {
            guard let chunk = try input.read(upToCount: count - data.count), !chunk.isEmpty else {
                throw EngineError.unsupportedLink
            }
            data.append(chunk)
        }
        return data
    }

    static func run(arguments: [String]) async -> Never {
        guard acceptsOrigin(arguments) else { exit(1) }
        let accepted: Bool
        do {
            let payload = try readPayload(from: .standardInput)
            if let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
               object["type"] as? String == "downloadCookies" {
                let request = try DownloadCookieRequest.parse(payload)
                try DownloadCookieHandoff.save(request, directory: DownloadCookieHandoff.directory())
            } else {
                let request = try VideoCookieRequest.parse(payload)
                try await VideoLoginStore.shared.save(request)
            }
            accepted = true
        } catch {
            accepted = false
        }
        let payload = Data((accepted ? "{\"ok\":true}" : "{\"ok\":false}").utf8)
        var length = UInt32(payload.count).littleEndian
        do {
            try withUnsafeBytes(of: &length) { try FileHandle.standardOutput.write(contentsOf: $0) }
            try FileHandle.standardOutput.write(contentsOf: payload)
        } catch { exit(1) }
        exit(accepted ? 0 : 1)
    }

    static func isInstalled(executable: URL, home: URL = .homeDirectory) -> Bool {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path),
              let data = try? Data(contentsOf: manifestFile(home: home)),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return manifest["name"] as? String == host
            && manifest["type"] as? String == "stdio"
            && manifest["path"] as? String == executable.path
            && manifest["allowed_origins"] as? [String] == [origin]
    }

    private static func manifestFile(home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
            .appendingPathComponent(host + ".json")
    }

    static func install(executable: URL, home: URL = .homeDirectory) throws {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw EngineError.binaryNotFound
        }
        let file = manifestFile(home: home)
        let directory = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": host, "description": "Mulee video login", "path": executable.path,
            "type": "stdio", "allowed_origins": [origin]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: file, options: .atomic)
    }
}

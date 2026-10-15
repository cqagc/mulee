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
        let header = try readExactly(4, from: input)
        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        guard length > 0, length <= VideoCookieRequest.maximumBytes else { throw EngineError.unsupportedLink }
        return try VideoCookieRequest.parse(readExactly(Int(length), from: input))
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
            let request = try readRequest(from: .standardInput)
            try await VideoLoginStore.shared.save(request)
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

    static func install(executable: URL, home: URL = .homeDirectory) throws {
        guard executable.isFileURL, FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw EngineError.binaryNotFound
        }
        let directory = home.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manifest: [String: Any] = [
            "name": host, "description": "Mulee video login", "path": executable.path,
            "type": "stdio", "allowed_origins": [origin]
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent(host + ".json"), options: .atomic)
    }
}

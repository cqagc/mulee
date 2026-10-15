import Darwin
import Foundation

struct Aria2Configuration: Sendable {
    let stateDirectory: URL
    let port: UInt16
    let secret: String
    var options: EngineOptions

    var fileURL: URL { stateDirectory.appendingPathComponent("aria2.conf") }
    var sessionURL: URL { stateDirectory.appendingPathComponent("aria2.session") }
    var logURL: URL { stateDirectory.appendingPathComponent("aria2.log") }
    var arguments: [String] { ["--conf-path=\(fileURL.path)"] }

    static func makeSecret() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in
            let digits = String(UInt8.random(in: .min ... .max, using: &generator), radix: 16)
            return digits.count == 1 ? "0" + digits : digits
        }.joined()
    }

    var runtimeOptions: [String: String] {
        let connections = min(16, max(1, options.connectionsPerServer))
        return [
            "dir": options.downloadDirectory.path,
            "max-concurrent-downloads": String(max(1, options.maxConcurrentDownloads)),
            "max-connection-per-server": String(connections),
            "split": String(connections),
            "max-overall-download-limit": String(max(0, options.downloadLimit)),
            "max-overall-upload-limit": String(max(0, options.uploadLimit))
        ]
    }

    func contents() throws -> String {
        var values = runtimeOptions.merging([
            "enable-rpc": "true",
            "rpc-listen-all": "false",
            "rpc-listen-port": String(port),
            "rpc-secret": secret,
            "disable-ipv6": "true",
            "min-split-size": "1M",
            "continue": "true",
            "file-allocation": "none",
            "disk-cache": "\(max(0, options.diskCacheMegabytes))M",
            "save-session": sessionURL.path,
            "save-session-interval": "30",
            "max-download-result": "1000",
            "keep-unfinished-download-result": "true",
            "auto-file-renaming": "true",
            "allow-overwrite": "false",
            "check-certificate": "true",
            "follow-torrent": "false",
            "enable-dht": "false",
            "bt-enable-lpd": "false",
            "console-log-level": "warn",
            "log": logURL.path,
            "log-level": "warn",
            "user-agent": "Mulee/0.1",
            "stop-with-process": String(ProcessInfo.processInfo.processIdentifier),
            "no-proxy": "localhost,127.0.0.1,::1"
        ]) { _, new in new }
        if FileManager.default.fileExists(atPath: sessionURL.path) {
            values["input-file"] = sessionURL.path
        }
        guard values.values.allSatisfy({ !$0.contains("\n") && !$0.contains("\r") }) else {
            throw EngineError.invalidResponse("aria2 配置不能包含换行符")
        }
        return values.keys.sorted().map { "\($0)=\(values[$0, default: ""])" }.joined(separator: "\n") + "\n"
    }

    func write() throws {
        let data = Data(try contents().utf8)
        try FileManager.default.createDirectory(
            at: stateDirectory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let temporaryURL = stateDirectory.appendingPathComponent(".aria2-\(UUID().uuidString).conf")
        let descriptor = open(temporaryURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { unlink(temporaryURL.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
        guard rename(temporaryURL.path, fileURL.path) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
    }
}

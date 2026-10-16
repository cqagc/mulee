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
            "max-overall-download-limit": String(max(0, options.downloadLimit))
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
            // Avoid preallocating/zero-filling on APFS; sparse extents are allocated as data arrives.
            "file-allocation": "none",
            // aria2 M suffix means 1024 * 1024 bytes; this is its global write-cache budget.
            "disk-cache": "\(max(0, options.diskCacheMegabytes))M",
            "save-session": sessionURL.path,
            "save-session-interval": "30",
            "max-download-result": "1000",
            "keep-unfinished-download-result": "true",
            "auto-file-renaming": "true",
            "allow-overwrite": "false",
            "check-certificate": "true",
            "console-log-level": "warn",
            "log": logURL.path,
            "log-level": "warn",
            "user-agent": DownloadRequestContext.safariUserAgent,
            "max-tries": "5",
            "retry-wait": "5",
            "lowest-speed-limit": "1K",
            "connect-timeout": "30",
            "timeout": "60",
            "stop-with-process": String(ProcessInfo.processInfo.processIdentifier),
            "no-proxy": "localhost,127.0.0.1,::1"
        ]) { _, new in new }
        if FileManager.default.fileExists(atPath: sessionURL.path) {
            values["input-file"] = sessionURL.path
        }
        guard values.values.allSatisfy({ !$0.utf8.contains(where: { [0, 10, 13].contains($0) }) }) else {
            throw EngineError.invalidResponse(String(localized: "aria2 配置不能包含换行符", bundle: .module))
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

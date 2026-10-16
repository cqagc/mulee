import Darwin
import Foundation

/// 沿用已授权的共享容器；一次性交接文件最多保留六十秒。
public enum DownloadCookieHandoff {
    public static func directory() throws -> URL {
        let directory = try VideoCookieHandoff.directory().appendingPathComponent("download-cookies", isDirectory: true)
        try prepare(directory)
        return directory
    }

    private static func prepare(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw EngineError.unsupportedLink }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }

    public static func save(_ request: DownloadCookieRequest, directory: URL, now: Date = .now) throws {
        let data = try JSONEncoder().encode(request)
        _ = try DownloadCookieRequest.parse(data)
        try prepare(directory)
        try cleanup(directory: directory, now: now)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".pending")
        try YtDlpCookieFile.writePrivate(data, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: temporary.path)
        let target = directory.appendingPathComponent(request.token)
        guard rename(temporary.path, target.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    public static func cleanup(directory: URL, now: Date = .now) throws {
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values.contentModificationDate, now.timeIntervalSince(modified) >= 60 {
                try FileManager.default.removeItem(at: file)
            }
        }
    }

    public static func take(token: String, url: URL, directory: URL, now: Date = .now) throws -> String? {
        guard DownloadCookieRequest.isValidToken(token) else { throw EngineError.unsupportedLink }
        try cleanup(directory: directory, now: now)
        let source = directory.appendingPathComponent(token)
        let claim = directory.appendingPathComponent(UUID().uuidString + ".pending")
        guard rename(source.path, claim.path) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        defer { try? FileManager.default.removeItem(at: claim) }
        let values = try claim.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: claim.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= DownloadCookieRequest.maximumBytes,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let modified = values.contentModificationDate, now.timeIntervalSince(modified) < 60 else { return nil }
        let request = try DownloadCookieRequest.parse(Data(contentsOf: claim))
        guard request.token == token, request.url == url else { return nil }
        return request.cookie
    }
}

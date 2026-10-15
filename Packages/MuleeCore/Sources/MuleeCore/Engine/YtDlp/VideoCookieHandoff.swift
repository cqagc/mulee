import Darwin
import Foundation

/// Safari 的凭据只落在双方签名授权的 App Group，不回退到公共临时目录。
public enum VideoCookieHandoff {
    public static let groupIdentifier = "LV69DG6R9Y.com.cqagc.mulee.video-login"

    public static func directory() throws -> URL {
        guard let root = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw EngineError.invalidResponse(String(localized: "无法访问浏览器登录状态共享容器", bundle: .module))
        }
        let directory = root.appendingPathComponent("VideoLogin", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return directory
    }

    public static func save(_ request: VideoCookieRequest, directory: URL) throws {
        let data = try JSONEncoder().encode(request)
        _ = try VideoCookieRequest.parse(data)
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".pending")
        try YtDlpCookieFile.writePrivate(data, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let target = directory.appendingPathComponent(request.site.rawValue + ".json")
        guard rename(temporary.path, target.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    /// rename 先认领本次交接，避免导入后删除并发到达的新凭据。
    public static func take(site: VideoSite, directory: URL) throws -> (request: VideoCookieRequest, file: URL)? {
        guard site != .other else { return nil }
        let source = directory.appendingPathComponent(site.rawValue + ".json")
        let claim = directory.appendingPathComponent(UUID().uuidString + ".pending")
        guard rename(source.path, claim.path) == 0 else {
            if errno == ENOENT { return nil }
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        do {
            let values = try claim.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            let attributes = try FileManager.default.attributesOfItem(atPath: claim.path)
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= VideoCookieRequest.maximumBytes,
                  (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
                throw EngineError.invalidResponse(String(localized: "浏览器登录状态无效或超出限制", bundle: .module))
            }
            let request = try VideoCookieRequest.parse(Data(contentsOf: claim))
            guard request.site == site else { throw EngineError.unsupportedLink }
            return (request, claim)
        } catch {
            try? FileManager.default.removeItem(at: claim)
            throw error
        }
    }
}

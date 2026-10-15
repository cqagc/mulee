import Darwin
import Foundation

/// 每个子进程独占文件，禁止跟随符号链接，创建时即为 0600。
public struct YtDlpCookieFile: Sendable {
    public let url: URL

    public init(cookies: [VideoCookie], site: VideoSite, directory: URL = FileManager.default.temporaryDirectory) throws {
        guard cookies.count <= 256, cookies.allSatisfy({ $0.isValid(for: site) }) else {
            throw EngineError.invalidResponse(String(localized: "浏览器登录状态无效或超出限制", bundle: .module))
        }
        let now = Date().timeIntervalSince1970
        let rows = cookies.filter { $0.expirationDate.map { $0 > now } ?? true }.map { cookie in
            let domain = (cookie.httpOnly ? "#HttpOnly_" : "") + cookie.domain
            return [domain, cookie.hostOnly ? "FALSE" : "TRUE", cookie.path,
                    cookie.secure ? "TRUE" : "FALSE", String(Int64(cookie.expirationDate ?? 0)),
                    cookie.name, cookie.value].joined(separator: "\t")
        }
        let data = Data((["# Netscape HTTP Cookie File"] + rows + [""]).joined(separator: "\n").utf8)
        url = directory.appendingPathComponent("mulee-cookies-" + UUID().uuidString + ".txt")
        try Self.writePrivate(data, to: url)
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: url)
    }

    public static func writePrivate(_ data: Data, to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        do {
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let count = write(descriptor, bytes.baseAddress?.advanced(by: offset), bytes.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    guard count > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
                    offset += count
                }
            }
        } catch {
            unlink(url.path)
            throw error
        }
    }
}

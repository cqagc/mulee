import CoreServices
import Darwin
import Foundation
import MuleeCore
import OSLog

/// 来源只保留定位信息，避免把下载口令和临时授权写进文件元数据。
nonisolated enum DownloadProvenance {
    private static let logger = Logger(subsystem: "com.cqagc.mulee", category: "provenance")

    static func sanitizedSource(_ source: String, filename: String, video: Bool = false) -> String? {
        guard let separator = source.firstIndex(of: ":") else { return nil }
        let scheme = source[..<separator].lowercased()
        if scheme == "magnet" || scheme == "ed2k" {
            return scheme + ":" + filename
        }
        guard var components = URLComponents(string: source), components.scheme != nil else { return nil }
        guard ["http", "https", "ftp", "ftps", "file"].contains(scheme), scheme == "file" || components.host?.isEmpty == false else { return nil }
        components.user = nil
        components.password = nil
        let host = components.host?.lowercased() ?? ""
        let isYouTube = host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be"
        let isBilibili = host == "bilibili.com" || host.hasSuffix(".bilibili.com")
        let allowed = video && isYouTube ? ["v", "list"] : video && isBilibili ? ["p"] : []
        if video, isYouTube, let link = LinkParser.parse(source).first, let id = link.youtubeVideoID {
            components.scheme = "https"
            components.host = "www.youtube.com"
            components.port = nil
            components.path = "/watch"
            components.queryItems = [URLQueryItem(name: "v", value: id)]
                + (components.queryItems?.filter { $0.name == "list" } ?? [])
        } else {
            let query = components.queryItems?.filter { allowed.contains($0.name) }
            components.queryItems = query?.isEmpty == false ? query : nil
        }
        components.fragment = nil
        return components.url?.absoluteString
    }

    static func sources(for task: DownloadTask) -> [String] {
        var sources: [String] = []
        for source in [task.sourceLink, task.sourcePageURL?.absoluteString ?? task.requestContext?.referer?.absoluteString ?? ""] {
            if let cleaned = sanitizedSource(source, filename: task.name, video: task.kind == .video), !sources.contains(cleaned) {
                sources.append(cleaned)
            }
        }
        return sources
    }

    @concurrent static func apply(to file: URL, task: DownloadTask) async {
        apply(to: file, sources: sources(for: task))
    }

    @concurrent static func apply(to files: [URL], task: DownloadTask) async {
        var remaining = 10_000
        let sources = sources(for: task)
        for file in files {
            guard remaining > 0, !Task.isCancelled else { return }
            remaining -= apply(to: file, sources: sources, limit: remaining)
        }
    }

    @discardableResult static func apply(to file: URL, sources: [String], limit: Int = 10_000) -> Int {
        guard limit > 0 else { return 0 }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var count = 0
        func mark(_ url: URL) {
            guard count < limit else { return }
            count += 1
            do { try write(to: url, sources: sources) }
            catch { logger.error("无法写入下载来源属性：\(error.localizedDescription, privacy: .public)") }
        }
        do {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { return 0 }
            if values.isRegularFile == true || file.pathExtension.lowercased() == "app" { mark(file) }
            guard values.isDirectory == true, file.pathExtension.lowercased() != "app",
                  let enumerator = FileManager.default.enumerator(at: file, includingPropertiesForKeys: Array(keys), errorHandler: { _, error in
                      logger.error("无法读取下载目录：\(error.localizedDescription, privacy: .public)")
                      return true
                  }) else { return count }
            for case let item as URL in enumerator {
                guard count < limit, !Task.isCancelled else { break }
                do {
                    let itemValues = try item.resourceValues(forKeys: keys)
                    if itemValues.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if item.pathExtension.lowercased() == "app", itemValues.isDirectory == true {
                        mark(item)
                        enumerator.skipDescendants()
                    } else if itemValues.isRegularFile == true {
                        mark(item)
                    }
                } catch {
                    logger.error("无法读取下载来源目标：\(error.localizedDescription, privacy: .public)")
                }
            }
        } catch {
            logger.error("无法读取下载来源目标：\(error.localizedDescription, privacy: .public)")
        }
        return count
    }

    static func write(to file: URL, sources: [String]) throws {
        var properties: [String: Any] = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeOtherDownload,
            kLSQuarantineAgentNameKey as String: "Mulee",
            kLSQuarantineTimeStampKey as String: Date()
        ]
        if let source = sources.first.flatMap({ URL(string: $0) }) { properties[kLSQuarantineDataURLKey as String] = source }
        if sources.count > 1, let page = sources.last.flatMap({ URL(string: $0) }) { properties[kLSQuarantineOriginURLKey as String] = page }
        try (file as NSURL).setResourceValue(properties, forKey: .quarantinePropertiesKey)
        let data = try PropertyListSerialization.data(fromPropertyList: sources, format: .binary, options: 0)
        let result = data.withUnsafeBytes { bytes in
            setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", bytes.baseAddress, data.count, 0, XATTR_NOFOLLOW)
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

import Foundation

/// 有界下载、每日更新与原子缓存；文件位置由 App 注入，测试只用临时目录。
public actor PublicTrackerSubscriptionService {
    public typealias Loader = @Sendable (URL) async throws -> Data

    private let fileURL: URL
    private let loader: Loader
    private var cache: PublicTrackerCache
    private var isUpdating = false

    public init(fileURL: URL, loader: @escaping Loader = PublicTrackerSubscriptionService.download) {
        self.fileURL = fileURL
        self.loader = loader
        if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size <= 4 * 1_024 * 1_024, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode(PublicTrackerCache.self, from: data) {
            cache = saved
            cache.entries = saved.entries.mapValues { PublicTrackerList.parse($0.joined(separator: "\n")) }
        } else {
            cache = PublicTrackerCache()
        }
    }

    public func snapshot() -> PublicTrackerCache { cache }

    /// 返回失败的订阅数。失败尝试也落盘，避免每次启动都自动重试。
    @discardableResult
    public func refresh(subscriptions: [[URL]], force: Bool = false, now: Date = .now) async throws -> Int {
        guard !isUpdating, force || cache.isExpired(at: now) else { return 0 }
        isUpdating = true
        defer { isUpdating = false }
        cache.lastAttempt = now
        try save()
        var failures = 0
        for addresses in subscriptions {
            try Task.checkCancellation()
            guard let primary = addresses.first else { continue }
            var fetched: [String]?
            for address in addresses {
                do {
                    let data = try await loader(address)
                    try Task.checkCancellation()
                    fetched = try PublicTrackerList.decode(data)
                    break
                } catch {
                    try Task.checkCancellation()
                }
            }
            if let fetched {
                cache.entries[primary.absoluteString] = fetched
                cache.updatedAt = now
            } else {
                failures += 1
            }
        }
        // Removed subscriptions cannot accumulate indefinitely in the cache.
        let active = Set(subscriptions.compactMap(\.first).map(\.absoluteString))
        cache.entries = cache.entries.filter { active.contains($0.key) }
        try save()
        return failures
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(cache).write(to: fileURL, options: .atomic)
    }

    public static func download(_ url: URL) async throws -> Data {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw PublicTrackerError.invalidSubscriptions
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 25
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PublicTrackerError.invalidResponse
        }
        guard response.expectedContentLength <= Int64(PublicTrackerList.maximumResponseSize) else {
            throw PublicTrackerError.responseTooLarge
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < PublicTrackerList.maximumResponseSize else { throw PublicTrackerError.responseTooLarge }
            data.append(byte)
        }
        return data
    }
}

import Foundation
import Observation
import zlib

/// 先在临时文件中校验，再原子替换缓存；网络失败不影响正在使用的名单。
@Observable
final class IPBlocklistUpdater {
    typealias Download = (URL) async throws -> Data
    nonisolated static let maximumBytes = 50 * 1_024 * 1_024
    nonisolated static let interval: TimeInterval = 7 * 24 * 60 * 60

    private struct State: Codable {
        var url = ""
        var attemptedAt: Date?
        var updatedAt: Date?
        var result: String?
    }

    private let directory: URL
    private let download: Download
    private var state = State()
    private var loaded = false
    private(set) var isUpdating = false
    private(set) var lastUpdate: Date?
    private(set) var result: String?
    private(set) var revision = 0

    init(directory: URL? = nil, download: @escaping Download = IPBlocklistUpdater.downloadURL) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Mulee/ip-blocklist", directoryHint: .isDirectory)
        self.download = download
    }

    var cachedFile: URL? {
        let file = directory.appendingPathComponent("subscription.dat")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    func refresh(
        url text: String, now: Date = .now,
        validate: (URL) async throws -> Void
    ) async {
        guard !isUpdating else { return }
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: directory.appendingPathComponent("state.json")),
               let saved = try? JSONDecoder().decode(State.self, from: data) { state = saved }
            lastUpdate = state.updatedAt
            result = state.result
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if state.url == text, let attempted = state.attemptedAt,
           now.timeIntervalSince(attempted) < Self.interval { return }
        isUpdating = true
        defer { isUpdating = false }
        state.url = text
        state.attemptedAt = now
        let temporary = directory.appendingPathComponent(UUID().uuidString + ".dat")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { throw UpdateError.invalidURL }
            let downloaded = try await download(url)
            guard downloaded.count <= Self.maximumBytes else { throw UpdateError.tooLarge }
            let data = try await Self.decoded(downloaded)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: temporary, options: .atomic)
            try await validate(temporary)
            try Task.checkCancellation()
            // write(.atomic) 在同一目录替换；校验和下载错误均不会触碰旧缓存。
            try data.write(to: directory.appendingPathComponent("subscription.dat"), options: .atomic)
            state.updatedAt = now
            state.result = String(localized: "黑名单已更新，将与本地名单合并。")
            revision += 1
        } catch {
            state.result = String(localized: "黑名单更新失败，已保留旧名单。请检查网址、网络和文件格式。")
        }
        lastUpdate = state.updatedAt
        result = state.result
        if let data = try? JSONEncoder().encode(state) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? data.write(to: directory.appendingPathComponent("state.json"), options: .atomic)
        }
    }

    @concurrent nonisolated static func downloadURL(_ url: URL) async throws -> Data {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw UpdateError.invalidResponse
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw UpdateError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw UpdateError.tooLarge }
            data.append(byte)
        }
        return data
    }

    @concurrent nonisolated static func decoded(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        guard data.starts(with: [0x1f, 0x8b]) else { return data }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw UpdateError.invalidResponse
        }
        defer { inflateEnd(&stream) }
        return try data.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(data.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 64 * 1_024)
            while true {
                try Task.checkCancellation()
                let status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let count = chunk.count - Int(stream.avail_out)
                guard output.count <= maximumBytes - count else { throw UpdateError.tooLarge }
                output.append(contentsOf: chunk.prefix(count))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw UpdateError.invalidResponse }
                    return output
                }
                guard status == Z_OK, count > 0 else { throw UpdateError.invalidResponse }
            }
        }
    }

    private nonisolated enum UpdateError: Error {
        case invalidURL, invalidResponse, tooLarge
    }
}

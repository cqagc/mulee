import Foundation

/// 流式读取并限制实际响应体大小，不能只相信 Content-Length。
struct TorrentFileDownloader: Sendable {
    static let maximumSize = 20 * 1_024 * 1_024
    let session: URLSession

    func download(_ url: URL, into directory: URL) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw EngineError.unsupportedLink
        }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            defer { bytes.task.cancel() }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw EngineError.invalidResponse("无法下载种子文件，服务器响应异常")
            }
            guard response.expectedContentLength <= Int64(Self.maximumSize) else { throw Self.tooLarge() }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < Self.maximumSize else { throw Self.tooLarge() }
                if data.isEmpty, byte != 100 { throw EngineError.invalidResponse("下载的内容不是有效的种子文件") }
                data.append(byte)
            }
            guard data.first == 100 else { throw EngineError.invalidResponse("下载的种子文件为空") }
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
            let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("torrent")
            try data.write(to: file, options: .atomic)
            return file
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EngineError {
            throw error
        } catch {
            throw EngineError.rpc(code: 6, message: "无法下载或保存种子文件，请检查网络和保存目录的访问权限")
        }
    }

    private static func tooLarge() -> EngineError {
        .invalidResponse("种子文件超过大小上限（20 MB）")
    }
}

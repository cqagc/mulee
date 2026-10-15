import Foundation
import MuleeCore

/// 仅使用已经准备好的工具，打开面板不会触发工具安装。
actor VideoPlaylistProvider {
    static let shared = VideoPlaylistProvider()
    private let installer = ManagedToolInstaller()

    func entries(for url: URL, channel: YtDlpChannel) async throws -> [YtDlpPlaylistEntry] {
        let cookies = try await VideoLoginStore.shared.cookies(for: .bilibili)
        if let entries = await YtDlpPlaylist.fetchMetadata(url: url, cookies: cookies) {
            try Task.checkCancellation()
            return entries
        }
        try Task.checkCancellation()
        var binary = try await installer.installedURL(for: .ytDlp(channel: channel))
        #if DEBUG
        let homebrew = URL(filePath: "/opt/homebrew/bin/yt-dlp")
        if binary == nil, FileManager.default.isExecutableFile(atPath: homebrew.path) { binary = homebrew }
        #endif
        guard let binary else { throw EngineError.binaryNotFound }
        return try await YtDlpPlaylist.fetch(url: url, binary: binary, cookies: cookies)
    }
}

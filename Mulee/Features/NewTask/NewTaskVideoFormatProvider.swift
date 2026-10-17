import Foundation
import MuleeCore

/// 面板只使用已安装工具；格式探测不触发下载或安装。
actor NewTaskVideoFormatProvider {
    static let shared = NewTaskVideoFormatProvider()
    private let installer = ManagedToolInstaller()

    func formats(for url: URL, site: VideoSite, channel: YtDlpChannel) async throws -> [YtDlpFormat] {
        try await metadata(for: url, site: site, channel: channel).formats
    }

    func metadata(for url: URL, site: VideoSite, channel: YtDlpChannel) async throws -> YtDlpVideoMetadata {
        guard let binary = try await installer.installedURL(for: .ytDlp(channel: channel)) else {
            throw YtDlpFormats.ListingError.failed
        }
        let cookies = try await VideoLoginStore.shared.cookies(for: site)
        let deno = try await installer.installedURL(for: .deno)
        return try await YtDlpFormats.fetchMetadata(url: url, site: site, binary: binary, cookies: cookies, deno: deno, proxy: .current())
    }
}

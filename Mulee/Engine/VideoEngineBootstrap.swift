import Foundation
import MuleeCore

/// 工具准备独立于其他引擎；正式分发只使用校验过的托管工具。
nonisolated struct VideoEngineBootstrap: Sendable {
    let stateDirectory: URL
    let installer: ManagedToolInstaller
    let ffmpegURL: URL?
    let allowHomebrewFallback: Bool

    init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "Mulee", directoryHint: .isDirectory),
        allowHomebrewFallback: Bool = _isDebugAssertConfiguration(),
        ffmpegURL: URL? = VideoEngineBootstrap.homebrew("ffmpeg")
    ) {
        stateDirectory = directory.appending(path: "yt-dlp", directoryHint: .isDirectory)
        installer = ManagedToolInstaller(directory: directory.appending(path: "bin", directoryHint: .isDirectory))
        self.allowHomebrewFallback = allowHomebrewFallback
        // TODO: 接入可信的 arm64 ffmpeg 静态构建，替代 Homebrew 路径。
        self.ffmpegURL = ffmpegURL
    }

    func makeEngine(configuration: VideoEngineConfiguration) async throws -> YtDlpEngine {
        let binary = try await resolve(.ytDlp(channel: configuration.channel), homebrewName: "yt-dlp")
        let deno = try await resolve(.deno, homebrewName: "deno")
        try Task.checkCancellation()
        let engine = YtDlpEngine(
            stateDirectory: stateDirectory, binaryURL: binary, installer: installer,
            ffmpegURL: ffmpegURL, denoURL: deno,
            quality: configuration.quality, channel: configuration.channel,
            allowHomebrewFallback: allowHomebrewFallback,
            updatesEnabled: configuration.updateBeforeRetry
        )
        try await configuration.apply(to: engine)
        return engine
    }

    private func resolve(_ tool: ManagedTool, homebrewName: String) async throws -> URL {
        if let installed = try await installer.installedURL(for: tool) { return installed }
        if allowHomebrewFallback, let fallback = Self.homebrew(homebrewName) { return fallback }
        return try await installer.install(tool)
    }

    private static func homebrew(_ name: String) -> URL? {
        let url = URL(filePath: "/opt/homebrew/bin/" + name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

import Foundation
import MuleeCore

/// 工具准备独立于其他引擎；正式分发只使用校验过的托管工具。
actor VideoEngineBootstrap {
    let stateDirectory: URL
    let installer: ManagedToolInstaller
    private(set) var ffmpegURL: URL?
    private(set) var ffmpegPreparationError: String?
    let allowHomebrewFallback: Bool
    private let homebrewLookup: @Sendable (String) -> URL?

    init(
        directory: URL = URL.applicationSupportDirectory.appending(path: "Mulee", directoryHint: .isDirectory),
        allowHomebrewFallback: Bool = _isDebugAssertConfiguration(),
        installer: ManagedToolInstaller? = nil,
        homebrewLookup: @escaping @Sendable (String) -> URL? = VideoEngineBootstrap.homebrew
    ) {
        stateDirectory = directory.appending(path: "yt-dlp", directoryHint: .isDirectory)
        self.installer = installer ?? ManagedToolInstaller(directory: directory.appending(path: "bin", directoryHint: .isDirectory))
        #if DEBUG
        self.allowHomebrewFallback = allowHomebrewFallback
        #else
        self.allowHomebrewFallback = false
        #endif
        self.homebrewLookup = homebrewLookup
    }

    func makeEngine(configuration: VideoEngineConfiguration) async throws -> YtDlpEngine {
        let binary = try await resolve(.ytDlp(channel: configuration.channel), homebrewName: "yt-dlp")
        let deno = try await resolve(.deno, homebrewName: "deno")
        do {
            ffmpegURL = try await resolveFFmpeg()
            ffmpegPreparationError = nil
        } catch {
            try Task.checkCancellation()
            ffmpegURL = nil
            ffmpegPreparationError = EngineStatusPresentation.errorMessage(error)
        }
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

    /// 两个工具保持在同一目录，yt-dlp 可由 ffmpeg 文件路径找到 ffprobe。
    func resolveFFmpeg() async throws -> URL {
        let ffmpeg = try await installer.installedURL(for: .ffmpeg)
        let ffprobe = try await installer.installedURL(for: .ffprobe)
        if let ffmpeg, ffprobe != nil { return ffmpeg }
        if ffmpeg == nil, ffprobe == nil, allowHomebrewFallback,
           let fallback = homebrewLookup("ffmpeg"), let probe = homebrewLookup("ffprobe"),
           fallback.deletingLastPathComponent() == probe.deletingLastPathComponent() {
            return fallback
        }
        let installed = try await installer.install(.ffmpeg)
        _ = try await installer.install(.ffprobe)
        return installed
    }

    private func resolve(_ tool: ManagedTool, homebrewName: String) async throws -> URL {
        if let installed = try await installer.installedURL(for: tool) { return installed }
        if allowHomebrewFallback, let fallback = homebrewLookup(homebrewName) { return fallback }
        return try await installer.install(tool)
    }

    nonisolated private static func homebrew(_ name: String) -> URL? {
        let url = URL(filePath: "/opt/homebrew/bin/" + name)
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
}

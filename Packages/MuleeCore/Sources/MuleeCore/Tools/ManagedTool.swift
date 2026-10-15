import Foundation

/// 可在运行时下载、验证并安装的外部工具。
public struct ManagedTool: Sendable, Hashable {
    public typealias Extraction = ManagedToolExtraction

    public let name: String
    public let downloadURL: URL
    public let checksumURL: URL
    /// 固定版本的压缩包摘要；设置后无需另行下载校验文件。
    public let sha256: String?
    public let extraction: Extraction
    public let versionArguments: [String]

    public init(
        name: String, downloadURL: URL, checksumURL: URL,
        extraction: Extraction = .executable, versionArguments: [String] = ["--version"],
        sha256: String? = nil
    ) {
        self.name = name
        self.downloadURL = downloadURL
        self.checksumURL = checksumURL
        self.sha256 = sha256
        self.extraction = extraction
        self.versionArguments = versionArguments
    }

    public static func ytDlp(channel: YtDlpChannel = .stable) -> Self {
        let repository = channel == .stable ? "yt-dlp" : "yt-dlp-nightly-builds"
        let base = URL(string: "https://github.com/yt-dlp/\(repository)/releases/latest/download/")
            ?? URL(fileURLWithPath: "/invalid")
        return Self(
            name: "yt-dlp-\(channel.rawValue)",
            downloadURL: base.appendingPathComponent("yt-dlp_macos"),
            checksumURL: base.appendingPathComponent("SHA2-256SUMS")
        )
    }

    public static var deno: Self {
        let base = URL(string: "https://github.com/denoland/deno/releases/latest/download/")
            ?? URL(fileURLWithPath: "/invalid")
        return Self(
            name: "deno", downloadURL: base.appendingPathComponent("deno-aarch64-apple-darwin.zip"),
            checksumURL: base.appendingPathComponent("deno-aarch64-apple-darwin.zip.sha256sum"),
            extraction: .zip(entry: "deno")
        )
    }

    public static var ffmpeg: Self {
        ffmpegTool(name: "ffmpeg", sha256: "c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924")
    }

    public static var ffprobe: Self {
        ffmpegTool(name: "ffprobe", sha256: "fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6")
    }

    private static func ffmpegTool(name: String, sha256: String) -> Self {
        // Martin Riedl arm64 release 9.0.2；摘要来自同目录的 <name>.zip.sha256。
        // 更新时同时替换构建目录和两份摘要，并复核签名、许可证与 -version；见 docs/BUILDING.md。
        let base = URL(string: "https://ffmpeg.martin-riedl.de/download/macos/arm64/1789931890_9.0.2/")
            ?? URL(fileURLWithPath: "/invalid")
        return Self(
            name: name, downloadURL: base.appendingPathComponent(name + ".zip"),
            checksumURL: base.appendingPathComponent(name + ".zip.sha256"),
            extraction: .zip(entry: name), versionArguments: ["-version"], sha256: sha256
        )
    }
}

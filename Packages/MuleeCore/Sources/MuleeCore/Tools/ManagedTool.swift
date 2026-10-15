import Foundation

/// 可在运行时下载、验证并安装的外部工具。
public struct ManagedTool: Sendable, Hashable {
    public typealias Extraction = ManagedToolExtraction

    public let name: String
    public let downloadURL: URL
    public let checksumURL: URL
    public let extraction: Extraction
    public let versionArguments: [String]

    public init(
        name: String, downloadURL: URL, checksumURL: URL,
        extraction: Extraction = .executable, versionArguments: [String] = ["--version"]
    ) {
        self.name = name
        self.downloadURL = downloadURL
        self.checksumURL = checksumURL
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
}

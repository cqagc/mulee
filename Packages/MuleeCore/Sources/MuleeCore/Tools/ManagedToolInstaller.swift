import CryptoKit
import Darwin
import Foundation

/// 下载函数必须把响应写入传入的临时路径；可注入假网络层。
public actor ManagedToolInstaller {
    public typealias Downloader = @Sendable (URL, URL) async throws -> Void

    public let directory: URL
    private let download: Downloader
    private var installations: [String: Task<URL, any Error>] = [:]

    public init(directory: URL? = nil, download: @escaping Downloader = ManagedToolInstaller.downloadFile) {
        self.directory = directory ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appendingPathComponent("Mulee/bin", isDirectory: true)
        self.download = download
    }

    public static func downloadFile(from url: URL, to destination: URL) async throws {
        let (temporary, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            throw EngineError.invalidResponse("工具下载失败：服务器响应异常")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    public func record(for tool: ManagedTool) throws -> ManagedToolRecord? {
        try validate(tool)
        let url = directory.appendingPathComponent(tool.name + ".json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(ManagedToolRecord.self, from: Data(contentsOf: url))
    }

    public func installedURL(for tool: ManagedTool) throws -> URL? {
        guard let record = try record(for: tool) else { return nil }
        let url = directory.appendingPathComponent(tool.name)
        guard FileManager.default.isExecutableFile(atPath: url.path),
              try Self.digest(url) == record.sha256 else { return nil }
        return url
    }

    public func install(_ tool: ManagedTool, force: Bool = false) async throws -> URL {
        try validate(tool)
        if let task = installations[tool.name] { return try await task.value }
        if !force, let installed = try installedURL(for: tool) { return installed }
        let task = Task { try await performInstallation(tool) }
        installations[tool.name] = task
        defer { installations[tool.name] = nil }
        return try await task.value
    }

    /// 支持 GNU SHA2-256SUMS 和 Deno 的单文件 sha256sum。
    public static func checksum(in text: String, filename: String) throws -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard let first = fields.first, first.count == 64,
                  first.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { continue }
            if fields.count == 1 || String(fields[1]).trimmingCharacters(in: CharacterSet(charactersIn: "*")) == filename {
                return first.lowercased()
            }
        }
        throw EngineError.invalidResponse("校验和文件中找不到 \(filename)")
    }

    private func validate(_ tool: ManagedTool) throws {
        guard !tool.name.isEmpty, tool.name != ".", tool.name != "..",
              !tool.name.contains("/"), !tool.name.contains("\\") else {
            throw EngineError.invalidResponse("工具名称无效")
        }
    }

    private func performInstallation(_ tool: ManagedTool) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".install-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        let archive = staging.appendingPathComponent("download")
        let sums = staging.appendingPathComponent("checksums")
        try await download(tool.downloadURL, archive)
        try await download(tool.checksumURL, sums)
        let expected = try Self.checksum(
            in: String(contentsOf: sums, encoding: .utf8), filename: tool.downloadURL.lastPathComponent
        )
        guard try Self.digest(archive) == expected else {
            throw EngineError.invalidResponse("SHA256 校验失败，未安装工具")
        }
        let executable: URL
        switch tool.extraction {
        case .executable:
            executable = archive
        case .zip(let entry):
            guard !entry.contains("/"), entry != ".", entry != "..", !entry.isEmpty else {
                throw EngineError.invalidResponse("压缩包入口无效")
            }
            // 只提取指定入口，避免压缩包路径穿越或覆盖其他文件。
            executable = staging.appendingPathComponent("executable")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", archive.path, entry]
            guard fm.createFile(atPath: executable.path, contents: nil) else {
                throw EngineError.launchFailed("无法创建工具临时文件")
            }
            let handle = try FileHandle(forWritingTo: executable)
            defer { try? handle.close() }
            process.standardOutput = handle
            process.standardError = FileHandle.nullDevice
            try process.run()
            while process.isRunning { try await Task.sleep(for: .milliseconds(20)) }
            guard process.terminationStatus == 0 else { throw EngineError.invalidResponse("工具解压失败") }
        }
        let result = executable.path.withCString { removexattr($0, "com.apple.quarantine", 0) }
        if result != 0, errno != ENOATTR { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let version = try await YtDlpProcess.capture(binary: executable, arguments: tool.versionArguments)
        guard version.status == 0 else { throw EngineError.invalidResponse("工具版本检查失败：\(version.output)") }
        let record = ManagedToolRecord(
            version: version.output.trimmingCharacters(in: .whitespacesAndNewlines),
            updatedAt: Date(), sha256: try Self.digest(executable)
        )
        let target = directory.appendingPathComponent(tool.name)
        // POSIX rename 在同一个卷内原子替换，读者不会看到半写入的文件。
        guard rename(executable.path, target.path) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(tool.name + ".json"), options: .atomic)
        return target
    }

    private static func digest(_ file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
    }
}

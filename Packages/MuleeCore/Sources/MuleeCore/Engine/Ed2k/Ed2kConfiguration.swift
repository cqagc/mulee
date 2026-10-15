import Foundation

/// 配置文本按行合并，保留非 Mulee 管理的键、注释和分节。
struct Ed2kConfiguration: Sendable {
    let stateDirectory: URL
    let port: UInt16
    let password: String
    var options: EngineOptions
    var settings: Ed2kEngineSettings

    var url: URL { stateDirectory.appendingPathComponent("amule.conf") }
    var temporaryDirectory: URL { stateDirectory.appendingPathComponent("Temp", isDirectory: true) }
    static let serverListURL = "https://upd.emule-security.org/server.met"
    static let kadNodesURL = "https://upd.emule-security.org/nodes.dat"

    /// Cfg_Path 存储 Latin-1 码点形式的文件名字节；EC 路径则直接用 UTF-8。
    static func universalPath(_ url: URL) -> String {
        String(String.UnicodeScalarView(url.path.utf8.map { UnicodeScalar(UInt32($0)) ?? "?" }))
    }

    static func limitInKiB(_ bytes: Int64) throws -> UInt64 {
        guard bytes >= 0 else { throw ECError.rejected(String(localized: "限速不能小于 0", bundle: .module)) }
        let value = UInt64(bytes) / 1024 + (bytes % 1024 == 0 ? 0 : 1)
        guard value <= UInt32.max else { throw ECError.rejected(String(localized: "限速超出电驴引擎范围", bundle: .module)) }
        return value
    }

    func managedValues() throws -> [String: [String: String]] {
        try settings.validate()
        for path in [stateDirectory, options.downloadDirectory] {
            guard path.isFileURL, path.path.hasPrefix("/"),
                  !path.path.contains(where: { $0.isNewline || $0 == "\0" }) else {
                throw ECError.rejected(String(localized: "下载目录或状态目录无效", bundle: .module))
            }
        }
        return [
            "eMule": [
                "Address": settings.connectToServers || settings.enableKad ? "" : "127.0.0.1",
                "Port": String(settings.tcpPort), "UDPPort": String(settings.udpPort),
                "UDPEnable": settings.connectToServers || settings.enableKad ? "1" : "0",
                "Autoconnect": settings.connectToServers || settings.enableKad ? "1" : "0",
                "Reconnect": settings.connectToServers || settings.enableKad ? "1" : "0",
                "ConnectToED2K": settings.connectToServers ? "1" : "0",
                "ConnectToKad": settings.enableKad ? "1" : "0",
                "UPnPEnabled": "0", "Serverlist": "0",
                "AddServerListFromServer": "0", "AddServerListFromClient": "0",
                "IncomingDir": Self.universalPath(options.downloadDirectory),
                "TempDir": Self.universalPath(temporaryDirectory),
                "MaxDownload": String(try Self.limitInKiB(options.downloadLimit)),
                "MaxUpload": String(try Self.limitInKiB(settings.uploadLimit)),
                "ShareHiddenFiles": "0", "AutoRescanSharedDirs": "0",
                "ExcludeSharePatterns": settings.shareCompletedFiles
                    ? ".DS_Store|._*|.Spotlight-V100|.Trashes|.fseventsd|.DocumentRevisions-V100|.TemporaryItems|.apdisk|Thumbs.db|ehthumbs.db|desktop.ini|.directory" : "*",
                "ExcludeSharePatternsUseRegex": "0",
                "Ed2kServersUrl": Self.serverListURL, "KadNodesUrl": Self.kadNodesURL
            ],
            "ExternalConnect": [
                "AcceptExternalConnections": "1", "ECAddress": "127.0.0.1",
                "ECNetworkInterface": "", "RequireEncryption": "0",
                "ECPort": String(port), "ECPassword": ECAuthentication.passwordHash(password),
                "UPnPECEnabled": "0", "TransmitOnlyUploadingClients": "0"
            ],
            "Obfuscation": [
                "IsClientCryptLayerSupported": settings.obfuscation ? "1" : "0",
                "IsCryptLayerRequested": settings.obfuscation ? "1" : "0",
                "IsClientCryptLayerRequired": "0"
            ],
            "WebServer": ["Enabled": "0"], "AmuleApi": ["Enabled": "0"],
            "MediaMetadata": ["Enabled": "0"]
        ]
    }

    func contents(preserving original: String) throws -> String {
        var pending = try managedValues()
        let managed = pending
        var output: [String] = []
        var section = ""
        func appendRemaining() {
            for key in (pending[section] ?? [:]).keys.sorted() {
                if let value = pending[section]?[key] { output.append("\(key)=\(value)") }
            }
            pending[section] = nil
        }
        for line in original.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                appendRemaining()
                section = String(trimmed.dropFirst().dropLast())
                output.append(line)
            } else if let equals = trimmed.firstIndex(of: "="), !trimmed.hasPrefix("#"), !trimmed.hasPrefix(";") {
                let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
                if let value = managed[section]?[key] {
                    // Duplicate managed keys are all replaced, so none can override the loopback restriction.
                    output.append("\(key)=\(value)")
                    pending[section]?[key] = nil
                } else {
                    output.append(line)
                }
            } else {
                output.append(line)
            }
        }
        appendRemaining()
        for name in pending.keys.sorted() {
            output.append("[\(name)]")
            for key in (pending[name] ?? [:]).keys.sorted() {
                if let value = pending[name]?[key] { output.append("\(key)=\(value)") }
            }
        }
        return output.joined(separator: "\n") + "\n"
    }

    func write() throws {
        _ = try managedValues()
        for directory in [stateDirectory, temporaryDirectory, options.downloadDirectory] {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        for directory in [stateDirectory, temporaryDirectory] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        let original = FileManager.default.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : ""
        try Self.writePrivate(Data(try contents(preserving: original).utf8), to: url)
        for name in ["shareddir.dat", "shareddir-explicit.dat", "shareddir-recursive.dat"] {
            try Self.writePrivate(Data(), to: stateDirectory.appendingPathComponent(name))
        }
    }

    static func writePrivate(_ data: Data, to url: URL) throws {
        // .atomic writes an adjacent temporary file then renames; 0700 parent protects the write window.
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

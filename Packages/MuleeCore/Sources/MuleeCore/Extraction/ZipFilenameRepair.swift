import Foundation

/// 名称映射必须按条目序号、CRC 和大小校验。不能校验时保留整棵原始名称树。
enum ZipFilenameRepair {
    static func repair(archive: URL, rawRoot: URL, listing: String, encoding: ArchiveFilenameEncoding) throws -> (URL, Bool) {
        let metadata = try ZipFilenameDirectory.read(archive)
        let listed = SevenZipEntry.parse(listing)
        guard !metadata.isEmpty, metadata.count == listed.count else { return (rawRoot, false) }
        var mappings: [(URL, String, Bool)] = []
        var componentSources: [String: String] = [:]
        var knownFiles = Set<String>()
        for (entry, actual) in zip(metadata, listed) {
            guard actual.size == entry.size, actual.crc == entry.crc || (entry.size == 0 && actual.crc == nil) else {
                return (rawRoot, false)
            }
            let decoded = entry.unicodePath ?? (entry.isUTF8 ? String(data: entry.bytes, encoding: .utf8) : FilenameEncodingDetector.decode(entry.bytes, encoding: encoding))
            guard let decoded else { return (rawRoot, false) }
            try ArchivePathSafety.validate(path: decoded)
            try ArchivePathSafety.validate(path: actual.path)
            let sourceName = actual.path.replacingOccurrences(of: "\\", with: "/")
            let targetName = decoded.replacingOccurrences(of: "\\", with: "/")
            let source = rawRoot.appendingPathComponent(sourceName)
            guard FileManager.default.fileExists(atPath: source.path) else { return (rawRoot, false) }
            let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            let isDirectory = values.isDirectory == true
            guard isDirectory || values.isRegularFile == true else { return (rawRoot, false) }
            if !isDirectory {
                guard values.fileSize.map(UInt64.init) == entry.size else { return (rawRoot, false) }
                knownFiles.insert(source.standardizedFileURL.path)
            }
            let sourceComponents = sourceName.split(separator: "/").map(String.init)
            let targetComponents = targetName.split(separator: "/").map(String.init)
            guard sourceComponents.count == targetComponents.count else { return (rawRoot, false) }
            for length in 1...targetComponents.count {
                let targetKey = targetComponents.prefix(length).joined(separator: "/").precomposedStringWithCanonicalMapping.lowercased()
                let sourceKey = sourceComponents.prefix(length).joined(separator: "/").precomposedStringWithCanonicalMapping
                if let previous = componentSources[targetKey], previous != sourceKey { return (rawRoot, false) }
                componentSources[targetKey] = sourceKey
            }
            mappings.append((source, targetName, isDirectory))
        }
        guard let enumerator = FileManager.default.enumerator(at: rawRoot, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return (rawRoot, false)
        }
        for case let item as URL in enumerator {
            if try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true && !knownFiles.contains(item.standardizedFileURL.path) {
                return (rawRoot, false)
            }
        }
        if mappings.allSatisfy({ $0.0.standardizedFileURL == rawRoot.appendingPathComponent($0.1).standardizedFileURL }) {
            return (rawRoot, true)
        }
        let repaired = rawRoot.deletingLastPathComponent().appendingPathComponent("decoded", isDirectory: true)
        try FileManager.default.createDirectory(at: repaired, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var moved: [(URL, URL)] = []
        do {
            for (source, name, isDirectory) in mappings {
                let target = repaired.appendingPathComponent(name, isDirectory: isDirectory)
                try FileManager.default.createDirectory(at: isDirectory ? target : target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !isDirectory {
                    try FileManager.default.moveItem(at: source, to: target)
                    moved.append((source, target))
                }
            }
            return (repaired, true)
        } catch {
            // 所有移动都在隔离临时目录内；出错后完整回滚，不能部分改名。
            for (source, target) in moved.reversed() { try FileManager.default.moveItem(at: target, to: source) }
            try FileManager.default.removeItem(at: repaired)
            return (rawRoot, false)
        }
    }
}

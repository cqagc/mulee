import Foundation

enum ArchivePathSafety {
    static func validate(path: String) throws {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard !normalized.isEmpty, !normalized.hasPrefix("/"),
              !normalized.contains(":"), !normalized.contains("\0"),
              !normalized.unicodeScalars.contains(where: { $0.value < 32 }),
              !normalized.components(separatedBy: "/").contains("..") else { throw ExtractionFailure.unsafePath }
    }

    static func validate(listing: String) throws {
        var pathCount = 0
        for line in listing.components(separatedBy: "\n") {
            if line.hasPrefix("Path = ") {
                try validate(path: String(line.dropFirst(7)))
                pathCount += 1
            }
            let lower = line.lowercased()
            if lower.hasPrefix("symbolic link = ") || lower.hasPrefix("hard link = ") ||
                (lower.hasPrefix("attributes = ") && lower.split(separator: " ").contains(where: { $0.hasPrefix("l") })) {
                // 所有链接都拒绝，避免链接链、硬链接和后续条目借链接写出临时目录。
                throw ExtractionFailure.unsafePath
            }
        }
        guard pathCount > 0 else { throw ExtractionFailure.damagedArchive }
    }

    static func validate(zip: URL, encoding: ArchiveFilenameEncoding) throws {
        for entry in try ZipFilenameDirectory.read(zip) {
            guard !entry.isLink else { throw ExtractionFailure.unsafePath }
            let name = entry.unicodePath ?? (entry.isUTF8 ? String(data: entry.bytes, encoding: .utf8) : FilenameEncodingDetector.decode(entry.bytes, encoding: encoding))
            guard let name else { throw ExtractionFailure.damagedArchive }
            try validate(path: name)
        }
    }

    static func validateTree(_ root: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else {
            throw ExtractionFailure.damagedArchive
        }
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true,
                  item.resolvingSymlinksInPath().path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw ExtractionFailure.unsafePath
            }
        }
    }
}

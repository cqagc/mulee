import Foundation

enum Ed2kLinkParser: Sendable {
    static func parse(_ text: String, original: String? = nil) -> ParsedLink? {
        let fields = text.components(separatedBy: "|")
        guard fields.count >= 6,
              fields[0].lowercased() == "ed2k://",
              fields[1].lowercased() == "file",
              fields.last == "/",
              let fileName = fields[2].removingPercentEncoding, !fileName.isEmpty,
              !fields[3].isEmpty, fields[3].utf8.allSatisfy({ (48...57).contains($0) }),
              let size = Int64(fields[3]), size > 0,
              fields[4].utf8.count == 32,
              fields[4].utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else { return nil }

        return .ed2k(fileName: fileName, size: size, hash: fields[4].uppercased(), original: original ?? text)
    }
}

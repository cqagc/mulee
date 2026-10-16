import Foundation

enum MagnetLinkParser: Sendable {
    static func parse(_ text: String, original: String) -> ParsedLink? {
        guard text.lowercased().hasPrefix("magnet:?") else { return nil }

        var infoHash: String?
        var displayName: String?
        for parameter in text.dropFirst("magnet:?".count).split(separator: "&") {
            let fields = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { continue }
            let name = String(fields[0]).removingPercentEncoding?.lowercased()
            let value = String(fields[1])

            if name == "xt", infoHash == nil,
               let topic = value.removingPercentEncoding,
               topic.lowercased().hasPrefix("urn:btih:") {
                let hash = String(topic.dropFirst("urn:btih:".count))
                if hash.utf8.count == 40, hash.utf8.allSatisfy({
                    (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
                }) {
                    infoHash = hash.lowercased()
                } else {
                    infoHash = Base32.decodeHex(hash)
                }
            } else if name == "xt", infoHash == nil,
                      let topic = value.removingPercentEncoding?.lowercased(), topic.hasPrefix("urn:btmh:1220") {
                let hash = String(topic.dropFirst("urn:btmh:1220".count))
                if hash.count == 64, InfoHashLink.magnet(for: hash) != nil { infoHash = hash }
            } else if name == "dn", displayName == nil {
                displayName = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
            }
        }

        guard let infoHash else { return nil }
        return .magnet(infoHash: infoHash, displayName: displayName, original: original)
    }
}

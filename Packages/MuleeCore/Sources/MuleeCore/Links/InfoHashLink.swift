import Foundation

public enum InfoHashLink {
    public static func magnet(for text: String) -> String? {
        let hash = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isHex = hash.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        if hash.count == 64, isHex { return "magnet:?xt=urn:btmh:1220" + hash.lowercased() }
        if hash.count == 40, isHex { return "magnet:?xt=urn:btih:" + hash.lowercased() }
        if hash.count == 32, let hex = Base32.decodeHex(hash) { return "magnet:?xt=urn:btih:" + hex }
        return nil
    }
}

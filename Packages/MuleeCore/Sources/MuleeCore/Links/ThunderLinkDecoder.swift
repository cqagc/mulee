import Foundation

enum ThunderLinkDecoder: Sendable {
    static func decode(_ text: String) -> String? {
        guard text.lowercased().hasPrefix("thunder://") else { return nil }
        var payload = String(text.dropFirst("thunder://".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = payload.utf8.count % 4
        guard remainder != 1 else { return nil }
        if remainder != 0 {
            payload.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: payload) else { return nil }

        let gb18030 = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
            )
        )
        guard let decoded = String(data: data, encoding: .utf8) ?? String(data: data, encoding: gb18030),
              decoded.hasPrefix("AA"), decoded.hasSuffix("ZZ"), decoded.count > 4 else { return nil }
        return String(decoded.dropFirst(2).dropLast(2))
    }
}

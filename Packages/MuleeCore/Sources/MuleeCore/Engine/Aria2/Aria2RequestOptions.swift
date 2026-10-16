import Foundation

enum Aria2RequestOptions {
    static func values(context: DownloadRequestContext, checksum: DownloadChecksum?) throws -> [String: Aria2RPCValue] {
        try context.validate()
        var values: [String: Aria2RPCValue] = [
            "user-agent": .string(context.userAgent ?? context.headers.first { $0.key.lowercased() == "user-agent" }?.value
                ?? DownloadRequestContext.safariUserAgent)
        ]
        if let referer = context.referer?.absoluteString ?? context.headers.first(where: { $0.key.lowercased() == "referer" })?.value {
            values["referer"] = .string(referer)
        }
        if let name = context.suggestedFilename { values["out"] = .string(name) }
        var headers = context.withoutCookie.headers
        // 专属选项优先，避免重复头覆盖已确认的来源、UA 或 Cookie。
        headers = headers.filter { !["user-agent", "referer"].contains($0.key.lowercased()) }
        var lines = headers.keys.sorted().map { "\($0): \(headers[$0, default: ""])" }
        if let cookie = context.requestCookie { lines.append("Cookie: \(cookie)") }
        if !lines.isEmpty { values["header"] = .array(lines.map(Aria2RPCValue.string)) }
        if let checksum { values["checksum"] = .string(checksum.aria2Value) }
        return values
    }
}

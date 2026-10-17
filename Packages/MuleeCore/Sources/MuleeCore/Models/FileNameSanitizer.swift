import Foundation

/// 把远端标题限制为一个可见的文件名，不能让列表名变成路径。
public enum FileNameSanitizer {
    public static func sanitize(_ name: String, fallback: String = "") -> String {
        let cleaned = clean(name)
        if !cleaned.isEmpty { return cleaned }
        let safeFallback = clean(fallback)
        return safeFallback.isEmpty ? String(localized: "播放列表", bundle: .module) : safeFallback
    }

    private static func clean(_ name: String) -> String {
        let scalars = name.unicodeScalars.map { scalar -> String in
            // 只替换控制码，保留表情中的连接符，再按完整字符限制字节数。
            if scalar.properties.generalCategory == .control || "/:\\".unicodeScalars.contains(scalar) {
                return " "
            }
            return String(scalar)
        }.joined()
        var value = scalars.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(".") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var result = ""
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= 160 else { break }
            result.append(character)
            bytes += count
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

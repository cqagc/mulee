import Foundation

/// 把用户粘贴的一段文本解析成下载链接列表。
///
/// 规则（实现见各方法）：
/// - 按空白和换行切分，每段独立识别，忽略无法识别的内容，保持原顺序，去掉完全相同的重复项。
/// - `thunder://` 链接：base64 解码后去掉首尾的 `AA` 与 `ZZ`，再对得到的链接递归识别（可能是 http、ed2k 或磁力）。
/// - `magnet:?xt=urn:btih:` 支持 40 位十六进制和 32 位 base32 哈希，统一输出 40 位十六进制小写。
/// - `ed2k://|file|名称|大小|哈希|...` 名称做百分号解码，哈希统一大写，大小必须是正整数。
/// - http/https 链接中，bilibili.com、b23.tv、youtube.com、youtu.be 识别为视频，其他识别为 HTTP 直链。
/// - ftp 链接识别为 HTTP 直链。
public enum LinkParser {
    public static func parse(_ text: String) -> [ParsedLink] {
        // 先提取完整的 ed2k，避免文件名里的空格被切开。
        let ed2kMatches = text.matches(
            of: #/(?i)ed2k://\|file\|(?:(?!ed2k://)[^\r\n])*?\|//#
        )
        var links: [ParsedLink] = []
        var seen: Set<ParsedLink> = []
        var start = text.startIndex

        for match in ed2kMatches {
            appendLinks(in: text[start..<match.range.lowerBound], to: &links, seen: &seen)
            if let link = Ed2kLinkParser.parse(String(match.output)), seen.insert(link).inserted {
                links.append(link)
            }
            start = match.range.upperBound
        }
        appendLinks(in: text[start...], to: &links, seen: &seen)
        return links
    }

    private static func appendLinks(
        in text: Substring,
        to links: inout [ParsedLink],
        seen: inout Set<ParsedLink>
    ) {
        for part in text.split(whereSeparator: \.isWhitespace) {
            // 从协议头开始识别，允许前面紧贴中文。全角句读（，。；：！？、…）一律视为链接结束：
            // URL 里不会出现未编码的全角句读，而「链接，提取码 abcd」这类写法很常见。
            // 全角括号、书名号等可能是文件名的一部分，保留在链接内，结尾多出的单个括号再修剪。
            let matches = part.matches(
                of: #/(?i)(?:https?://|ftp://|thunder://|magnet:\?)[^\s，。；：！？、…]+/#
            )
            for match in matches {
                let candidate = trimmingPunctuation(String(match.output))
                if let link = parseCandidate(candidate), seen.insert(link).inserted {
                    links.append(link)
                }
            }
        }
    }

    private static func trimmingPunctuation(_ text: String) -> String {
        var text = text
        let openingCharacters: [Character: Character] = [
            ")": "(", "]": "[", "}": "{", "）": "（", "」": "「", "』": "『",
            "】": "【", "》": "《", "〉": "〈", "”": "“", "’": "‘", ">": "<"
        ]
        while let last = text.last {
            if "，。；：！？、…,.;:!?".contains(last) {
                text.removeLast()
            } else if let opening = openingCharacters[last],
                      text.filter({ $0 == last }).count > text.filter({ $0 == opening }).count {
                text.removeLast()
            } else if "\"'".contains(last), text.filter({ $0 == last }).count.isMultiple(of: 2) == false {
                text.removeLast()
            } else {
                break
            }
        }
        return text
    }

    private static func parseCandidate(
        _ candidate: String,
        original: String? = nil,
        decodedFromThunder: Bool = false
    ) -> ParsedLink? {
        let original = original ?? candidate
        let lowercased = candidate.lowercased()

        if lowercased.hasPrefix("thunder://") {
            guard let decoded = ThunderLinkDecoder.decode(candidate) else { return nil }
            return parseCandidate(decoded, original: original, decodedFromThunder: true)
        }
        if lowercased.hasPrefix("magnet:?") {
            return MagnetLinkParser.parse(candidate, original: original)
        }
        if lowercased.hasPrefix("ed2k://") {
            return Ed2kLinkParser.parse(candidate, original: original)
        }

        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp"].contains(scheme),
              let host = url.host?.lowercased(), !host.isEmpty else { return nil }

        if scheme != "ftp" {
            if host == "bilibili.com" || host.hasSuffix(".bilibili.com") || host == "b23.tv" {
                return .video(url: url, site: .bilibili, original: original)
            }
            if host == "youtube.com" || host.hasSuffix(".youtube.com") || host == "youtu.be" {
                return .video(url: url, site: .youtube, original: original)
            }
        }
        return .http(url: url, decodedFromThunder: decodedFromThunder, original: original)
    }
}

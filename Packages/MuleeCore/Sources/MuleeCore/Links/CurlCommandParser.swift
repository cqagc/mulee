import Foundation

/// 只解析复制的命令文本；不调用 shell、不读取命令中指定的文件。
public enum CurlCommandParser {
    public struct Result: Sendable {
        public let urls: [String]
        public let context: DownloadRequestContext
        public let unknownOptions: [String]
    }

    public enum ParseError: String, Error, LocalizedError {
        case unsafe = "命令含有 Shell 操作符，无法安全识别。请只复制 cURL 请求。"
        case quotes = "命令的引号或转义不完整，请重新复制完整请求。"
        case argument = "请求选项缺少参数，请重新复制完整请求。"
        case cookieFile = "Cookie 文件不会被读取，请复制包含 Cookie 请求头的请求。"
        case noURL = "未找到可下载的地址，请检查 cURL 请求。"
        case invalid = "请求头或来源地址无效，请检查请求内容。"
        public var errorDescription: String? { rawValue }
    }

    public static func parse(_ text: String) throws -> Result {
        guard !["$(", "`", ";", "|", "&&", ">", "<"].contains(where: text.contains),
              !text.utf8.contains(0) else { throw ParseError.unsafe }
        let words = try tokenize(text)
        guard words.first?.lowercased() == "curl" else { throw ParseError.noURL }
        var urls: [String] = []
        var context = DownloadRequestContext()
        var unknown: [String] = []
        var index = 1
        var positional = false
        let ignored = ["--compressed", "--location", "-L", "--silent", "-s", "--show-error", "-S",
                       "--insecure", "-k", "--globoff", "-g", "--http1.1", "--http2", "--fail", "-f"]
        while index < words.count {
            let word = words[index]
            index += 1
            if word == "--" { positional = true; continue }
            let fields = word.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            var option = String(fields[0])
            var attached = fields.count == 2 ? String(fields[1]) : nil
            if !word.hasPrefix("--"), word.count > 2, ["-H", "-b", "-A", "-e"].contains(String(word.prefix(2))) {
                option = String(word.prefix(2))
                attached = String(word.dropFirst(2))
            }
            if !positional, ["-H", "--header", "-b", "--cookie", "-A", "--user-agent", "-e", "--referer", "--url"].contains(option) {
                let value: String
                if let attached { value = attached }
                else {
                    guard index < words.count, !words[index].hasPrefix("-") else { throw ParseError.argument }
                    value = words[index]
                    index += 1
                }
                switch option {
                case "-H", "--header":
                    guard !value.hasPrefix("@"), let colon = value.firstIndex(of: ":") else { throw ParseError.invalid }
                    let name = String(value[..<colon]).trimmingCharacters(in: .whitespaces)
                    let content = String(value[value.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                    if name.lowercased() == "cookie" { context.cookie = content }
                    else if name.lowercased() == "referer" {
                        guard let url = URL(string: content) else { throw ParseError.invalid }
                        context.referer = url
                    } else if name.lowercased() == "user-agent" { context.userAgent = content }
                    else {
                        context.headers = context.headers.filter { $0.key.lowercased() != name.lowercased() }
                        context.headers[name] = content
                    }
                case "-b", "--cookie":
                    guard value.contains("="), !value.hasPrefix("@") else { throw ParseError.cookieFile }
                    context.cookie = value
                case "-A", "--user-agent": context.userAgent = value
                case "-e", "--referer":
                    guard let url = URL(string: value) else { throw ParseError.invalid }
                    context.referer = url
                default: urls.append(value)
                }
            } else if !positional, ignored.contains(word) {
                continue
            } else if !positional, word.hasPrefix("-") {
                // 仅显示选项名，避免把未知参数中的凭据显示到提示或日志。
                let safeName = option.hasPrefix("--")
                    ? String(option.prefix(80).prefix { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
                    : String(option.prefix(2))
                unknown.append(safeName)
                if attached == nil, index < words.count, !words[index].hasPrefix("-") { index += 1 }
            } else if let url = URL(string: word), ["http", "https", "ftp"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
                urls.append(word)
            }
        }
        guard !urls.isEmpty else { throw ParseError.noURL }
        guard urls.allSatisfy({ value in
            guard let url = URL(string: value) else { return false }
            return ["http", "https", "ftp"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
                && url.user == nil && url.password == nil
        }) else { throw ParseError.invalid }
        do { try context.validate() } catch { throw ParseError.invalid }
        return Result(urls: urls, context: context, unknownOptions: Array(Set(unknown)).sorted())
    }

    private static func tokenize(_ text: String) throws -> [String] {
        let characters = Array(text)
        var words: [String] = []
        var word = ""
        var quote: Character?
        var started = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\\", quote != "'" {
                index += 1
                guard index < characters.count else { throw ParseError.quotes }
                if characters[index] == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
                if characters[index] != "\n" {
                    if quote == "\"", !["\"", "\\", "$"].contains(characters[index]) { word.append("\\") }
                    word.append(characters[index])
                    started = true
                }
            } else if let current = quote {
                if character == current { quote = nil }
                else { word.append(character) }
            } else if character == "'" || character == "\"" {
                quote = character
                started = true
            } else if character.isWhitespace {
                if character.isNewline { throw ParseError.unsafe }
                if started { words.append(word); word = ""; started = false }
            } else {
                word.append(character)
                started = true
            }
            index += 1
        }
        guard quote == nil else { throw ParseError.quotes }
        if started { words.append(word) }
        return words
    }
}

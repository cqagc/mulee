import Foundation

/// 每条输入都有结果；失败时不回退提取 cURL 文本里的局部 URL。
public enum SmartPasteParser {
    public struct Row: Sendable {
        public let line: Int
        public let links: [ParsedLink]
        public let context: DownloadRequestContext
        public let message: String
    }

    public static func parse(_ text: String) -> [Row] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        var rows: [Row] = []
        var index = 0
        while index < lines.count {
            let line = index + 1
            var input = lines[index].trimmingCharacters(in: .whitespaces)
            index += 1
            guard !input.isEmpty else { continue }
            let isCurl = input.lowercased() == "curl" || input.lowercased().hasPrefix("curl ") || input.lowercased().hasPrefix("curl\t")
            if isCurl {
                while input.hasSuffix("\\"), index < lines.count {
                    input += "\n" + lines[index]
                    index += 1
                }
            }
            do {
                let urls: [String]
                let context: DownloadRequestContext
                var message: String
                if isCurl {
                    let result = try CurlCommandParser.parse(input)
                    urls = result.urls
                    context = result.context
                    message = "已识别 cURL 请求"
                    if !result.unknownOptions.isEmpty { message += "；已忽略选项：" + result.unknownOptions.joined(separator: "、") }
                } else {
                    urls = [InfoHashLink.magnet(for: input) ?? input]
                    context = DownloadRequestContext()
                    message = "已识别下载链接"
                }
                let expanded = try urls.flatMap { try BatchURLExpander.expand($0) }
                guard expanded.count <= 1000 else { throw BatchURLExpander.ExpansionError.tooMany }
                let links = expanded.flatMap(LinkParser.parse)
                rows.append(Row(line: line, links: links, context: context,
                                message: links.isEmpty ? "未识别到可下载的链接，请检查地址或文件类型。" : message + "（\(links.count) 个）"))
            } catch {
                rows.append(Row(line: line, links: [], context: DownloadRequestContext(), message: error.localizedDescription))
            }
        }
        return rows
    }
}

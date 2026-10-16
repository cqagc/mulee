import Foundation

/// 每条输入都有结果；失败时不回退提取 cURL 文本里的局部 URL。
public enum SmartPasteParser {
    public struct Row: Sendable {
        public let line: Int
        public let links: [ParsedLink]
        public let context: DownloadRequestContext
        public let message: String
        public var isInfoHash: Bool = false

        public var isTorrentFile: Bool {
            !links.isEmpty && links.allSatisfy {
                if case .torrentFile = $0 { return true }
                return false
            }
        }
    }

    public static func parse(_ text: String) -> [Row] {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        var rows: [Row] = []
        var index = 0
        var expandedCount = 0
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
                var expanded: [String] = []
                for url in urls {
                    let batch = try BatchURLExpander.expand(url, limit: 1000 - expandedCount)
                    expandedCount += batch.count
                    expanded.append(contentsOf: batch)
                }
                let links = expanded.flatMap(LinkParser.parse)
                if !isCurl, !links.isEmpty, links.allSatisfy({
                    if case .torrentFile = $0 { return true }
                    return false
                }) {
                    message = "已识别种子文件"
                }
                let firstURL = urls.first.flatMap { URL(string: $0) }
                let hasCredentials = context.requestCookie != nil || context.headers.keys.contains {
                    ["authorization", "proxy-authorization"].contains($0.lowercased())
                }
                let hasOtherHosts = isCurl && hasCredentials && expanded.contains {
                    guard let firstURL, let url = URL(string: $0) else { return false }
                    return !HTTPResourceProbe.sameHost(firstURL, url)
                }
                if hasOtherHosts {
                    for link in links {
                        var scoped = context
                        var reason = message
                        if let firstURL, let url = URL(string: link.original), !HTTPResourceProbe.sameHost(firstURL, url) {
                            scoped = context.withoutCookie
                            scoped.headers = scoped.headers.filter {
                                !["authorization", "proxy-authorization"].contains($0.key.lowercased())
                            }
                            reason += "；地址与首个下载地址的主机或端口不同，未附加登录凭据。"
                        }
                        rows.append(Row(line: line, links: [link], context: scoped, message: reason + "（1 个）"))
                    }
                } else {
                    rows.append(Row(line: line, links: links, context: context,
                                    message: links.isEmpty ? "未识别到可下载的链接，请检查地址或文件类型。" : message + "（\(links.count) 个）",
                                    isInfoHash: !isCurl && InfoHashLink.magnet(for: input) != nil))
                }
            } catch BatchURLExpander.ExpansionError.tooMany {
                return [Row(line: line, links: [], context: DownloadRequestContext(),
                            message: "下载地址展开总量超过 1000 个，请缩小范围或分批添加。")]
            } catch {
                rows.append(Row(line: line, links: [], context: DownloadRequestContext(), message: error.localizedDescription))
            }
        }
        return rows
    }
}

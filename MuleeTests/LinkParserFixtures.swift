import Foundation
import MuleeCore

/// 测试用的已解析链接。
enum LinkParserFixtures {
    static let oneHTTPLink: [ParsedLink] = LinkParser.parse("https://example.com/file.zip")
}

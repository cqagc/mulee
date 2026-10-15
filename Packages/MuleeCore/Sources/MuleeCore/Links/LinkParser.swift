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
        // TODO: 由 MuleeCore 工人实现
        []
    }
}

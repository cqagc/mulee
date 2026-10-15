import Foundation

/// 仅在一次同步 parse 调用内使用，不跨并发边界共享。
final class DanmakuXMLDelegate: NSObject, XMLParserDelegate {
    private let onComment: (DanmakuComment) throws -> Void
    private var attributes: String?
    private var text = ""
    private var insideComment = false
    private var oversized = false
    private(set) var total = 0
    private(set) var failure: (any Error)?

    init(onComment: @escaping (DanmakuComment) throws -> Void) {
        self.onComment = onComment
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        guard elementName == "d" else { return }
        total += 1
        insideComment = true
        attributes = attributeDict["p"]
        text = ""
        oversized = false
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        append(string)
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        append(String(decoding: CDATABlock, as: UTF8.self))
    }

    private func append(_ string: String) {
        guard insideComment, !oversized else { return }
        // 防止单条恶意弹幕无限增长；超出上限整条丢弃。
        guard text.utf8.count + string.utf8.count <= 65_536 else {
            oversized = true
            text = ""
            return
        }
        text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String,
        namespaceURI: String?, qualifiedName qName: String?
    ) {
        guard elementName == "d", insideComment else { return }
        insideComment = false
        guard !oversized, let attributes else { return }
        let fields = attributes.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count >= 4,
              let time = Double(fields[0]), time.isFinite, time >= 0, time < 3_600_000_000,
              let mode = Int(fields[1]), (1...6).contains(mode),
              let size = Double(fields[2]), size.isFinite, size > 0, size <= 1000,
              let color = UInt32(fields[3]), color <= 0xFFFFFF,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do {
            try Task.checkCancellation()
            try onComment(DanmakuComment(
                time: time, mode: mode, fontSize: size, color: color, text: text, ordinal: total
            ))
        } catch {
            failure = error
            parser.abortParsing()
        }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        // B 站弹幕不需要 DTD。禁止实体展开，避免超大实体耗尽内存。
        failure = CocoaError(.fileReadCorruptFile)
        parser.abortParsing()
    }
}

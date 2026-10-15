import Foundation

/// 使用有界输入缓冲和逐条回调，不把整个 XML 载入内存。
public struct DanmakuXMLParser: Sendable {
    public init() {}

    /// 空文件视为零条弹幕；结构损坏则抛错，由调用方保留原 XML。
    @discardableResult
    public func parse(xml: URL, onComment: @escaping (DanmakuComment) throws -> Void) throws -> Int {
        let stream = try DanmakuXMLInputStream(sourceURL: xml)
        if try xml.resourceValues(forKeys: [.fileSizeKey]).fileSize == 0 { return 0 }
        let delegate = DanmakuXMLDelegate(onComment: onComment)
        let parser = XMLParser(stream: stream)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let succeeded = parser.parse()
        if let error = stream.streamError { throw error }
        if let error = delegate.failure { throw error }
        guard succeeded else {
            throw parser.parserError ?? CocoaError(.fileReadCorruptFile)
        }
        return delegate.total
    }
}

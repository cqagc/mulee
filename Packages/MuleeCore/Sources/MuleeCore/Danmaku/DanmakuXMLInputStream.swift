import Foundation

/// 流式替换无效 UTF-8、移除 XML 1.0 禁止的字符，保留跨块多字节字符。
/// 实例只归属于一次同步 XMLParser 调用。
final class DanmakuXMLInputStream: InputStream {
    private let handle: FileHandle
    private var pending = Data()
    private var buffer = Data()
    private var offset = 0
    private var status: Stream.Status = .notOpen
    private var failure: (any Error)?

    init(sourceURL: URL) throws {
        handle = try FileHandle(forReadingFrom: sourceURL)
        super.init(data: Data())
    }

    deinit { try? handle.close() }

    override var streamStatus: Stream.Status { status }
    override var streamError: (any Error)? { failure }
    override var hasBytesAvailable: Bool { status == .open }
    override func open() { status = .open }
    override func close() { status = .closed }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool { false }

    override func read(_ output: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard len > 0 else { return 0 }
        do {
            while offset == buffer.count {
                try Task.checkCancellation()
                let chunk = try handle.read(upToCount: 32_768) ?? Data()
                pending.append(chunk)
                let ended = chunk.isEmpty
                var end = pending.count
                if !ended, end > 0 {
                    var lead = end - 1
                    while lead > 0, pending[lead] & 0xC0 == 0x80 { lead -= 1 }
                    let byte = pending[lead]
                    let count = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                    if end - lead < count { end = lead }
                }
                let decoded = String(decoding: pending.prefix(end), as: UTF8.self)
                let scalars = decoded.unicodeScalars.filter {
                    $0.value == 9 || $0.value == 10 || $0.value == 13
                        || (0x20...0xD7FF).contains($0.value)
                        || (0xE000...0xFFFD).contains($0.value)
                        || (0x10000...0x10FFFF).contains($0.value)
                }
                buffer = Data(String(String.UnicodeScalarView(scalars)).utf8)
                offset = 0
                pending = Data(pending.dropFirst(end))
                if ended, buffer.isEmpty {
                    status = .atEnd
                    return 0
                }
            }
            let count = min(len, buffer.count - offset)
            buffer.copyBytes(to: output, from: offset..<(offset + count))
            offset += count
            return count
        } catch {
            failure = error
            status = .error
            return -1
        }
    }
}

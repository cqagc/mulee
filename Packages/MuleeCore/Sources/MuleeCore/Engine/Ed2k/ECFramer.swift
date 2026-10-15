import Foundation

/// 多次 append 可接收分片，也可一次取出多份粘连的报文。
struct ECFramer: Sendable {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [ECPacket] {
        buffer.append(data)
        var packets: [ECPacket] = []
        while buffer.count >= 8 {
            let header = Array(buffer.prefix(8))
            let flags = header[0..<4].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            let length = header[4..<8].reduce(0) { ($0 << 8) | Int($1) }
            guard length > 0, length <= ECCodec.maximumPacketLength else { throw ECError.malformed("报文长度超限") }
            guard buffer.count >= 8 + length else { break }
            let body = Data(buffer.dropFirst(8).prefix(length))
            packets.append(try ECCodec.decode(body: body, flags: flags))
            buffer = Data(buffer.dropFirst(8 + length))
        }
        return packets
    }
}

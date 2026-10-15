import Foundation
import zlib

/// 自行按上游 ECSocket / ECTag 规范实现；不宣告 large-tag-count 扩展。
enum ECCodec {
    static let maximumPacketLength = 32 * 1024 * 1024
    static let maximumDepth = 32

    static func logicalLength(_ tag: ECTag) -> Int {
        7 + (tag.children.isEmpty ? 0 : 2) + tag.data.count + tag.children.reduce(0) { $0 + logicalLength($1) }
    }

    static func encode(_ packet: ECPacket, utf8Numbers: Bool = false) throws -> Data {
        var body = encodedNumber(UInt64(packet.opcode), width: 1, utf8: utf8Numbers)
        body.append(try encodeTags(packet.tags, utf8: utf8Numbers, depth: 0))
        guard body.count <= maximumPacketLength else { throw ECError.malformed(String(localized: "报文过长", bundle: .module)) }
        return encodedNumber(utf8Numbers ? 0x22 : 0x20, width: 4)
            + encodedNumber(UInt64(body.count), width: 4) + body
    }

    private static func encodeTags(_ tags: [ECTag], utf8: Bool, depth: Int) throws -> Data {
        guard depth <= maximumDepth, tags.count < 0xffff else { throw ECError.malformed(String(localized: "tag 数量或深度超限", bundle: .module)) }
        var result = encodedNumber(UInt64(tags.count), width: 2, utf8: utf8)
        for tag in tags {
            guard tag.name <= 0x7fff else { throw ECError.malformed(String(localized: "tag 名称越界", bundle: .module)) }
            let children = tag.children.isEmpty ? Data() : try encodeTags(tag.children, utf8: utf8, depth: depth + 1)
            let length = tag.data.count + tag.children.reduce(0) { $0 + logicalLength($1) }
            guard length <= maximumPacketLength else { throw ECError.malformed(String(localized: "tag 过长", bundle: .module)) }
            result.append(encodedNumber(UInt64(tag.name) << 1 | (children.isEmpty ? 0 : 1), width: 2, utf8: utf8))
            result.append(encodedNumber(UInt64(tag.type), width: 1, utf8: utf8))
            result.append(encodedNumber(UInt64(length), width: 4, utf8: utf8))
            result.append(children)
            result.append(tag.data)
        }
        return result
    }

    static func encodedNumber(_ value: UInt64, width: Int, utf8: Bool = false) -> Data {
        guard utf8, value >= 0x80 else {
            return Data((0..<(utf8 ? 1 : width)).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) })
        }
        let length = value < 0x800 ? 2 : value < 0x10000 ? 3 : value < 0x200000 ? 4 : value < 0x4000000 ? 5 : 6
        var bytes = [UInt8](repeating: 0, count: length)
        var remainder = value
        for index in (1..<length).reversed() {
            bytes[index] = 0x80 | UInt8(remainder & 0x3f)
            remainder >>= 6
        }
        bytes[0] = UInt8(truncatingIfNeeded: 0xff << (8 - length)) | UInt8(remainder)
        return Data(bytes)
    }

    static func decode(body: Data, flags: UInt32) throws -> ECPacket {
        guard flags & ~UInt32(0x23) == 0, flags & 0x20 != 0 else {
            throw ECError.malformed(String(localized: "不支持的 EC 标志", bundle: .module))
        }
        guard body.count <= maximumPacketLength else { throw ECError.malformed(String(localized: "报文过长", bundle: .module)) }
        let payload = flags & 1 != 0 ? try inflate(body) : body
        var reader = ECReader(bytes: Array(payload), utf8Numbers: flags & 2 != 0)
        let opcode = UInt8(try reader.number(1))
        let tags = try reader.tags()
        guard reader.offset == payload.count else { throw ECError.malformed(String(localized: "报文有多余数据", bundle: .module)) }
        return ECPacket(opcode: opcode, tags: tags)
    }

    private static func inflate(_ data: Data) throws -> Data {
        var capacity = min(max(1024, data.count * 4), maximumPacketLength)
        while true {
            var output = Data(count: capacity)
            var size = uLongf(capacity)
            var inputSize = uLong(data.count)
            let result = output.withUnsafeMutableBytes { destination in
                data.withUnsafeBytes { source in
                    uncompress2(destination.bindMemory(to: Bytef.self).baseAddress, &size,
                                source.bindMemory(to: Bytef.self).baseAddress, &inputSize)
                }
            }
            if result == Z_OK, inputSize == data.count {
                output.count = Int(size)
                return output
            }
            guard result == Z_BUF_ERROR, capacity < maximumPacketLength else {
                throw ECError.malformed(String(localized: "压缩报文无效或解压后过长", bundle: .module))
            }
            capacity = min(capacity * 2, maximumPacketLength)
        }
    }
}

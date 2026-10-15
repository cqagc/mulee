import Foundation

/// UTF8_NUMBERS 只影响结构字段，tag 的整数数据仍是大端原始字节。
struct ECReader {
    let bytes: [UInt8]
    let utf8Numbers: Bool
    var offset = 0

    mutating func raw(_ count: Int) throws -> Data {
        guard count >= 0, count <= bytes.count - offset else { throw ECError.malformed(String(localized: "报文被截断", bundle: .module)) }
        defer { offset += count }
        return Data(bytes[offset..<offset + count])
    }

    mutating func number(_ width: Int) throws -> UInt64 {
        if !utf8Numbers { return try raw(width).reduce(0) { ($0 << 8) | UInt64($1) } }
        let first = try raw(1)[0]
        if first < 0x80 { return UInt64(first) }
        // EC uses the original UTF-8 integer encoding, including 5/6-byte sequences.
        let length: Int
        switch first {
        case 0xc2...0xdf: length = 2
        case 0xe0...0xef: length = 3
        case 0xf0...0xf7: length = 4
        case 0xf8...0xfb: length = 5
        case 0xfc...0xfd: length = 6
        default: throw ECError.malformed(String(localized: "UTF-8 数字无效", bundle: .module))
        }
        var value = UInt64(first & (0x7f >> length))
        for byte in try raw(length - 1) {
            guard byte & 0xc0 == 0x80 else { throw ECError.malformed(String(localized: "UTF-8 数字无效", bundle: .module)) }
            value = (value << 6) | UInt64(byte & 0x3f)
        }
        let minima: [UInt64] = [0, 0, 0x80, 0x800, 0x10000, 0x200000, 0x4000000]
        guard value >= minima[length], value <= 0x7fffffff,
              value < (UInt64(1) << (width * 8)) else { throw ECError.malformed(String(localized: "UTF-8 数字越界", bundle: .module)) }
        return value
    }

    mutating func tags(depth: Int = 0) throws -> [ECTag] {
        guard depth <= ECCodec.maximumDepth else { throw ECError.malformed(String(localized: "tag 嵌套过深", bundle: .module)) }
        let count = Int(try number(2))
        guard count <= bytes.count - offset else { throw ECError.malformed(String(localized: "tag 数量无效", bundle: .module)) }
        var result: [ECTag] = []
        for _ in 0..<count {
            let encodedName = try number(2)
            let type = UInt8(try number(1))
            let length = Int(try number(4))
            guard length <= ECCodec.maximumPacketLength else { throw ECError.malformed(String(localized: "tag 过长", bundle: .module)) }
            let children = encodedName & 1 == 1 ? try tags(depth: depth + 1) : []
            let childrenLength = children.reduce(0) { $0 + ECCodec.logicalLength($1) }
            guard length >= childrenLength else { throw ECError.malformed(String(localized: "tag 长度小于子项", bundle: .module)) }
            let data = try raw(length - childrenLength)
            result.append(ECTag(name: UInt16(encodedName >> 1), type: type, data: data, children: children))
        }
        return result
    }
}

import Foundation
import Testing
import zlib
@testable import MuleeCore

struct ECCodecTests {
    @Test("整数采用最小宽度，值不受 UTF-8 数字标志影响", arguments: [false, true])
    func roundTrip(utf8: Bool) throws {
        let values: [UInt64] = [0, 127, 128, 255, 256, 65535, 65536, UInt64(UInt32.max), UInt64.max]
        let tags = values.map { ECTag.number(0x101, $0) }
        let packet = ECPacket(opcode: 9, tags: [
            .string(0, "虛構的繁體中文資料集.bin", children: tags),
            try .hash(0x31e, "0123456789ABCDEF0123456789ABCDEF"),
            ECTag(name: 0x7123, type: 0xfa, data: Data([0, 0xff, 0x55]), children: [.empty(0x7100)])
        ])
        var framer = ECFramer()
        let decoded = try framer.append(ECCodec.encode(packet, utf8Numbers: utf8))
        #expect(decoded == [packet])
        #expect(decoded.first?.tags.first?.children.compactMap(\.number) == values)
        #expect(tags.map(\.type) == [2, 2, 2, 2, 3, 3, 4, 4, 5])
    }

    @Test("独立线格式样本：有子项的 tag 长度不包含自身 child-count")
    func wireFixture() throws {
        let bytes = Data([
            0, 0, 0, 0x20, 0, 0, 0, 24,
            9, 0, 1,
            0, 1, 6, 0, 0, 0, 12,
            0, 1,
            0, 2, 2, 0, 0, 0, 1, 42,
            0x61, 0x62, 0x63, 0
        ])
        var framer = ECFramer()
        let packet = try #require(framer.append(bytes).first)
        #expect(packet.tags.first?.string == "abc")
        #expect(packet.tags.first?.children.first?.number == 42)
        #expect(try ECCodec.encode(packet) == bytes)
    }

    @Test("UTF-8 数字兼容 EC 的五、六字节编码", arguments: [UInt64(0x80), 0x800, 0x10000, 0x200000, 0x4000000, 0x7fffffff])
    func wideUTF8(_ number: UInt64) throws {
        var reader = ECReader(bytes: Array(ECCodec.encodedNumber(number, width: 4, utf8: true)), utf8Numbers: true)
        #expect(try reader.number(4) == number)
    }

    @Test("逐字节分片与多包粘连")
    func fragmentation() throws {
        let packet = ECPacket(opcode: 1, tags: [.string(0, "繁體")])
        let data = try ECCodec.encode(packet)
        var framer = ECFramer()
        var received: [ECPacket] = []
        for byte in data { received += try framer.append(Data([byte])) }
        received += try framer.append(data + data)
        #expect(received == [packet, packet, packet])
    }

    @Test("zlib 包和 UTF-8 数字压缩包", arguments: [false, true])
    func compressed(utf8: Bool) throws {
        let packet = ECPacket(opcode: 0x1f, tags: [.string(0x301, String(repeating: "虛構資料", count: 1000))])
        let wire = try ECCodec.encode(packet, utf8Numbers: utf8)
        let compressed = try compress(Data(wire.dropFirst(8)))
        let flags: UInt64 = utf8 ? 0x23 : 0x21
        let framed = ECCodec.encodedNumber(flags, width: 4)
            + ECCodec.encodedNumber(UInt64(compressed.count), width: 4) + compressed
        var framer = ECFramer()
        #expect(try framer.append(framed) == [packet])
    }

    @Test("长度、深度、压缩炸弹和截断拒绝")
    func defensiveLimits() throws {
        var framer = ECFramer()
        let header = Data([0, 0, 0, 0x20, 0x7f, 0xff, 0xff, 0xff])
        #expect(throws: ECError.self) { try framer.append(header) }
        var tag = ECTag.empty(1)
        for _ in 0...ECCodec.maximumDepth { tag = .empty(1, children: [tag]) }
        #expect(throws: ECError.self) { try ECCodec.encode(ECPacket(opcode: 1, tags: [tag])) }
        #expect(throws: ECError.self) { try ECCodec.decode(body: Data([1, 0, 1]), flags: 0x20) }
        #expect(throws: ECError.self) { try ECCodec.decode(body: Data([1, 0, 0]), flags: 0x28) }
        #expect(throws: ECError.self) { try ECCodec.decode(body: Data([1, 2, 3]), flags: 0x21) }
        // 独立构造深层输入，验证读取路径的深度上限，不能只测发送器。
        var nested = Data([0, 2, 1, 0, 0, 0, 0])
        for _ in 0...ECCodec.maximumDepth {
            nested = Data([0, 3, 1]) + ECCodec.encodedNumber(UInt64(nested.count), width: 4)
                + Data([0, 1]) + nested
        }
        let deepBody = Data([1, 0, 1]) + nested
        #expect(throws: ECError.self) { try ECCodec.decode(body: deepBody, flags: 0x20) }
        let bomb = try compress(Data(repeating: 0, count: ECCodec.maximumPacketLength + 1))
        #expect(throws: ECError.self) { try ECCodec.decode(body: bomb, flags: 0x21) }
        var invalidUTF8 = ECReader(bytes: [0xc0, 0x80], utf8Numbers: true)
        #expect(throws: ECError.self) { try invalidUTF8.number(2) }
    }

    private func compress(_ input: Data) throws -> Data {
        var length = compressBound(uLong(input.count))
        var output = Data(count: Int(length))
        let result = output.withUnsafeMutableBytes { destination in
            input.withUnsafeBytes { source in
                compress2(destination.bindMemory(to: Bytef.self).baseAddress, &length,
                          source.bindMemory(to: Bytef.self).baseAddress, uLong(input.count), Z_BEST_COMPRESSION)
            }
        }
        #expect(result == Z_OK)
        output.count = Int(length)
        return output
    }
}

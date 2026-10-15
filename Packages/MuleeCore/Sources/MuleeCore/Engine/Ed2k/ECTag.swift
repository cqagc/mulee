import Foundation

/// 保留未知 tag 的原始类型和值，业务层只读取认识的名称。
struct ECTag: Sendable, Equatable {
    var name: UInt16
    var type: UInt8
    var data: Data
    var children: [ECTag] = []

    static func number(_ name: UInt16, _ value: UInt64, width: Int? = nil, children: [ECTag] = []) -> Self {
        let size = width ?? (value <= 0xff ? 1 : value <= 0xffff ? 2 : value <= 0xffffffff ? 4 : 8)
        let type: UInt8 = size == 1 ? 2 : size == 2 ? 3 : size == 4 ? 4 : 5
        let bytes = (0..<size).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
        return Self(name: name, type: type, data: Data(bytes), children: children)
    }

    static func string(_ name: UInt16, _ value: String, children: [ECTag] = []) -> Self {
        Self(name: name, type: 6, data: Data(value.utf8) + Data([0]), children: children)
    }

    static func empty(_ name: UInt16, children: [ECTag] = []) -> Self {
        Self(name: name, type: 1, data: Data(), children: children)
    }

    static func hash(_ name: UInt16, _ hex: String) throws -> Self {
        guard hex.utf8.count == 32, hex.utf8.allSatisfy({
            (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
        }) else { throw ECError.malformed("文件哈希无效") }
        let chars = Array(hex.utf8)
        var bytes = Data()
        for index in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(decoding: chars[index...index + 1], as: UTF8.self), radix: 16) else {
                throw ECError.malformed("文件哈希无效")
            }
            bytes.append(byte)
        }
        return Self(name: name, type: 9, data: bytes)
    }

    var number: UInt64? {
        let widths: [UInt8: Int] = [2: 1, 3: 2, 4: 4, 5: 8]
        guard widths[type] == data.count else { return nil }
        return data.reduce(0) { ($0 << 8) | UInt64($1) }
    }

    var string: String? {
        guard type == 6, data.last == 0 else { return nil }
        return String(data: data.dropLast(), encoding: .utf8)
    }

    var hash: String? {
        guard type == 9, data.count == 16 else { return nil }
        return Self.hex(data)
    }

    func tag(_ name: UInt16) -> ECTag? { children.first { $0.name == name } }

    static func hex(_ data: Data) -> String {
        data.map {
            let value = String($0, radix: 16, uppercase: true)
            return value.count == 1 ? "0" + value : value
        }.joined()
    }
}

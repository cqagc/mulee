import Foundation

/// 保留原始 info 字节位置，避免重新编码改变 info-hash。
struct BencodeParser: Sendable {
    static let maximumLength = 20 * 1_024 * 1_024
    private let bytes: [UInt8]
    private var position = 0
    private var nodes = 0
    private(set) var infoRange: Range<Int>?

    init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumLength else { throw Self.invalid() }
        bytes = Array(data)
    }

    mutating func parse() throws -> BencodeValue {
        let value = try parseValue(depth: 0)
        guard position == bytes.count else { throw Self.invalid() }
        return value
    }

    private mutating func parseValue(depth: Int) throws -> BencodeValue {
        nodes += 1
        guard depth <= 64, nodes <= 200_000, position < bytes.count else { throw Self.invalid() }
        switch bytes[position] {
        case 105:
            position += 1
            let start = position
            while position < bytes.count, bytes[position] != 101 { position += 1 }
            guard position < bytes.count, position > start, position - start <= 20 else { throw Self.invalid() }
            let text = String(decoding: bytes[start..<position], as: UTF8.self)
            let digits = text.hasPrefix("-") ? text.dropFirst() : text[...]
            guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }),
                  !(digits.count > 1 && digits.first == "0"), text != "-0",
                  let number = Int64(text) else { throw Self.invalid() }
            position += 1
            return .integer(number)
        case 108:
            position += 1
            var values: [BencodeValue] = []
            while position < bytes.count, bytes[position] != 101 {
                values.append(try parseValue(depth: depth + 1))
            }
            try consumeEnd()
            return .list(values)
        case 100:
            position += 1
            var values: [Data: BencodeValue] = [:]
            while position < bytes.count, bytes[position] != 101 {
                let key = try parseBytes()
                guard values[key] == nil else { throw Self.invalid() }
                let start = position
                values[key] = try parseValue(depth: depth + 1)
                if depth == 0, key == Data("info".utf8) { infoRange = start..<position }
            }
            try consumeEnd()
            return .dictionary(values)
        case 48...57:
            return .bytes(try parseBytes())
        default:
            throw Self.invalid()
        }
    }

    private mutating func parseBytes() throws -> Data {
        let start = position
        var length = 0
        while position < bytes.count, (48...57).contains(bytes[position]) {
            let (product, multipliedOverflow) = length.multipliedReportingOverflow(by: 10)
            let (sum, addedOverflow) = product.addingReportingOverflow(Int(bytes[position] - 48))
            guard !multipliedOverflow, !addedOverflow, sum <= Self.maximumLength else { throw Self.invalid() }
            length = sum
            position += 1
        }
        guard position > start, position < bytes.count, bytes[position] == 58,
              !(position - start > 1 && bytes[start] == 48) else { throw Self.invalid() }
        position += 1
        guard length <= bytes.count - position else { throw Self.invalid() }
        let data = Data(bytes[position..<(position + length)])
        position += length
        return data
    }

    private mutating func consumeEnd() throws {
        guard position < bytes.count, bytes[position] == 101 else { throw Self.invalid() }
        position += 1
    }

    static func invalid() -> EngineError { .invalidResponse("种子文件无效或已损坏") }
}

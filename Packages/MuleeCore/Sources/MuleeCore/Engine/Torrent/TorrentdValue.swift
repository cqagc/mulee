import Foundation

/// JSON 信封中的动态值；整数保持 Int64 精度。
indirect enum TorrentdValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int64)
    case double(Double)
    case bool(Bool)
    case array([TorrentdValue])
    case object([String: TorrentdValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .integer(value) }
        else if let value = try? container.decode(Double.self) { self = .double(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([TorrentdValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: TorrentdValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

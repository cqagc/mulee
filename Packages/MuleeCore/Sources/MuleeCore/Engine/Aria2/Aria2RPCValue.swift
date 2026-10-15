import Foundation

indirect enum Aria2RPCValue: Codable, Sendable, Equatable {
    case string(String)
    case integer(Int)
    case array([Aria2RPCValue])
    case object([String: Aria2RPCValue])
    case null

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Int.self) { self = .integer(value) }
        else if let value = try? container.decode([Aria2RPCValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: Aria2RPCValue].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

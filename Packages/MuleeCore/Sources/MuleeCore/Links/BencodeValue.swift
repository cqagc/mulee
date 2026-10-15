import Foundation

indirect enum BencodeValue: Sendable {
    case bytes(Data)
    case integer(Int64)
    case list([BencodeValue])
    case dictionary([Data: BencodeValue])

    var bytes: Data? {
        if case .bytes(let value) = self { value } else { nil }
    }

    var integer: Int64? {
        if case .integer(let value) = self { value } else { nil }
    }

    var list: [BencodeValue]? {
        if case .list(let value) = self { value } else { nil }
    }

    var dictionary: [Data: BencodeValue]? {
        if case .dictionary(let value) = self { value } else { nil }
    }
}

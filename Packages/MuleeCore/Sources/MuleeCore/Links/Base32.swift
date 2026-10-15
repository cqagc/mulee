import Foundation

enum Base32: Sendable {
    /// BTIH 的 32 位 base32 恰好表示 20 字节，不接受填充或其他长度。
    static func decodeHex(_ text: String) -> String? {
        guard text.utf8.count == 32 else { return nil }

        var buffer: UInt32 = 0
        var bitCount = 0
        var hex = ""
        for character in text.utf8 {
            let value: UInt32
            switch character {
            case 65...90:
                value = UInt32(character - 65)
            case 97...122:
                value = UInt32(character - 97)
            case 50...55:
                value = UInt32(character - 50 + 26)
            default:
                return nil
            }
            buffer = (buffer << 5) | value
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                let byte = (buffer >> bitCount) & 0xff
                if byte < 16 {
                    hex.append("0")
                }
                hex.append(String(byte, radix: 16))
                buffer &= (1 << bitCount) - 1
            }
        }
        return hex
    }
}

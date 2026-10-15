struct ECPacket: Sendable, Equatable {
    var opcode: UInt8
    var tags: [ECTag] = []

    func tag(_ name: UInt16) -> ECTag? { tags.first { $0.name == name } }

    func checked(_ expected: UInt8 = ECCode.Op.noop) throws -> Self {
        if opcode == ECCode.Op.failed {
            throw ECError.rejected(Ed2kErrorDescriptions.operation(tag(ECCode.Tag.string)?.string))
        }
        guard opcode == expected else { throw ECError.malformed("操作回包类型不符（\(opcode)）") }
        return self
    }
}

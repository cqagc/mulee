import Foundation

/// 只读取中央目录，不把整个下载文件载入内存。
enum ZipFilenameDirectory {
    static func read(_ url: URL) throws -> [ZipFilenameEntry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        let size = try handle.seekToEnd()
        let tailSize = min(size, 65_557)
        try handle.seek(toOffset: size - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        guard tail.count >= 22 else { throw ExtractionFailure.damagedArchive }
        let ends = stride(from: tail.count - 22, through: 0, by: -1).filter {
            integer(tail, $0, 4) == 0x06054b50 && $0 + 22 + integer(tail, $0 + 20, 2) == tail.count
        }
        guard let end = ends.first else { throw ExtractionFailure.damagedArchive }
        let directorySize = integer(tail, end + 12, 4)
        let offset = integer(tail, end + 16, 4)
        // ZIP64 的名称由 7zz 列出；不把 0xffffffff 当成可分配长度。
        if directorySize == 0xffffffff || offset == 0xffffffff { return [] }
        guard directorySize <= 64 * 1024 * 1024, UInt64(offset) <= size,
              UInt64(directorySize) <= size - UInt64(offset) else { throw ExtractionFailure.damagedArchive }
        try handle.seek(toOffset: UInt64(offset))
        let data = try handle.read(upToCount: directorySize) ?? Data()
        var position = 0
        var entries: [ZipFilenameEntry] = []
        while position + 46 <= data.count, integer(data, position, 4) == 0x02014b50 {
            let nameLength = integer(data, position + 28, 2)
            let extraLength = integer(data, position + 30, 2)
            let commentLength = integer(data, position + 32, 2)
            let next = position + 46 + nameLength + extraLength + commentLength
            guard next <= data.count else { throw ExtractionFailure.damagedArchive }
            let attributes = integer(data, position + 38, 4)
            entries.append(ZipFilenameEntry(
                bytes: data.subdata(in: position + 46..<position + 46 + nameLength),
                isUTF8: integer(data, position + 8, 2) & 0x800 != 0,
                isLink: (attributes >> 16) & 0xf000 == 0xa000,
                crc: UInt32(integer(data, position + 16, 4)),
                size: UInt64(integer(data, position + 24, 4)),
                unicodePath: unicodePath(
                    extra: data.subdata(in: position + 46 + nameLength..<position + 46 + nameLength + extraLength),
                    name: data.subdata(in: position + 46..<position + 46 + nameLength)
                )
            ))
            position = next
        }
        guard position == data.count else { throw ExtractionFailure.damagedArchive }
        return entries
    }

    private static func unicodePath(extra: Data, name: Data) -> String? {
        var offset = 0
        var crc: UInt32 = 0xffffffff
        for byte in name {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xedb88320 : crc >> 1 }
        }
        crc ^= 0xffffffff
        while offset + 4 <= extra.count {
            let tag = integer(extra, offset, 2)
            let size = integer(extra, offset + 2, 2)
            guard offset + 4 + size <= extra.count else { return nil }
            if tag == 0x7075 && size >= 5 && extra[offset + 4] == 1 && UInt32(integer(extra, offset + 5, 4)) == crc {
                return String(data: extra.subdata(in: offset + 9..<offset + 4 + size), encoding: .utf8)
            }
            offset += 4 + size
        }
        return nil
    }

    private static func integer(_ data: Data, _ offset: Int, _ length: Int) -> Int {
        guard offset >= 0, offset + length <= data.count else { return 0 }
        return (0..<length).reduce(0) { $0 | Int(data[offset + $1]) << (8 * $1) }
    }
}

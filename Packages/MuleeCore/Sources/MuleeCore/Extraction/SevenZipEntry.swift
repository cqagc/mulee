import Foundation

struct SevenZipEntry: Sendable {
    let path: String
    let size: UInt64?
    let crc: UInt32?

    static func parse(_ listing: String) -> [SevenZipEntry] {
        var entries: [SevenZipEntry] = []
        var path: String?
        var size: UInt64?
        var crc: UInt32?
        for line in listing.components(separatedBy: "\n") {
            if line.hasPrefix("Path = ") {
                if let path { entries.append(SevenZipEntry(path: path, size: size, crc: crc)) }
                path = String(line.dropFirst(7))
                size = nil
                crc = nil
            } else if line.hasPrefix("Size = ") {
                size = UInt64(line.dropFirst(7))
            } else if line.hasPrefix("CRC = ") {
                crc = UInt32(line.dropFirst(6), radix: 16)
            }
        }
        if let path { entries.append(SevenZipEntry(path: path, size: size, crc: crc)) }
        return entries
    }
}

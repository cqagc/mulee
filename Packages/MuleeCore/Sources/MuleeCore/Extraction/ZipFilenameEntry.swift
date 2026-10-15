import Foundation

struct ZipFilenameEntry: Sendable {
    let bytes: Data
    let isUTF8: Bool
    let isLink: Bool
    let crc: UInt32
    let size: UInt64
    let unicodePath: String?
}

import Foundation

public enum ArchiveFilenameEncoding: String, Sendable, CaseIterable {
    case automatic = "自动检测"
    case utf8 = "UTF-8"
    case gbk = "GBK"
    case big5 = "Big5"
    case shiftJIS = "Shift-JIS"

    public var codePage: Int? {
        switch self {
        case .automatic, .utf8: nil
        case .gbk: 936
        case .big5: 950
        case .shiftJIS: 932
        }
    }
}

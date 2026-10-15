import Foundation

public struct ArchiveVolumeSet: Sendable, Equatable {
    public let isArchive: Bool
    public let isMultipart: Bool
    public let mainVolume: String?
    public let volumes: [String]
    public let missingVolumes: [String]
    /// 文件名不能证明末卷存在，未提供下载批次清单时需要用 7zz t 确认。
    public let completenessUnknown: Bool
}

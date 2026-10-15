import Foundation

public enum ExtractionFailure: Error, Sendable, Equatable, LocalizedError {
    case wrongPasswords
    case damagedArchive
    case missingVolumes([String])
    case insufficientSpace
    case unsafePath
    case executableMissing
    case passwordStorage
    case invalidPassword
    case cancelled
    case timedOut
    case fileOperation(String)

    public var errorDescription: String? {
        switch self {
        case .wrongPasswords: "密码都不对"
        case .damagedArchive: "压缩包损坏"
        case .missingVolumes: "分卷不全，等待其余分卷下载完成"
        case .insufficientSpace: "磁盘空间不足"
        case .unsafePath: "压缩包包含不安全的路径或链接"
        case .executableMissing: "找不到 7-Zip 解压工具"
        case .passwordStorage: "无法读取或保存解压密码"
        case .invalidPassword: "密码包含不支持的换行符或长度过长"
        case .cancelled: "解压已取消"
        case .timedOut: "解压工具响应超时"
        case .fileOperation(let message): "文件处理失败：\(message)"
        }
    }
}

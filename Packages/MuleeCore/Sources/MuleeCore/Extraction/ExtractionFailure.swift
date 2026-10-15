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
        case .wrongPasswords: String(localized: "密码都不对", bundle: .module)
        case .damagedArchive: String(localized: "压缩包损坏", bundle: .module)
        case .missingVolumes: String(localized: "分卷不全，等待其余分卷下载完成", bundle: .module)
        case .insufficientSpace: String(localized: "磁盘空间不足", bundle: .module)
        case .unsafePath: String(localized: "压缩包包含不安全的路径或链接", bundle: .module)
        case .executableMissing: String(localized: "找不到 7-Zip 解压工具", bundle: .module)
        case .passwordStorage: String(localized: "无法读取或保存解压密码", bundle: .module)
        case .invalidPassword: String(localized: "密码包含不支持的换行符或长度过长", bundle: .module)
        case .cancelled: String(localized: "解压已取消", bundle: .module)
        case .timedOut: String(localized: "解压工具响应超时", bundle: .module)
        case .fileOperation(let message): String(localized: "文件处理失败：\(message)", bundle: .module)
        }
    }
}

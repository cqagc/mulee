import Foundation

enum Ed2kErrorDescriptions {
    static func status(_ value: UInt64) -> String? {
        switch value {
        case 4: String(localized: "电驴文件读写失败，请检查下载目录权限（aMule 状态码 4）", bundle: .module)
        case 5: String(localized: "磁盘空间不足（aMule 状态码 5）", bundle: .module)
        case 6: String(localized: "电驴文件状态异常（aMule 状态码 6）", bundle: .module)
        default: nil
        }
    }

    static func operation(_ original: String?) -> String {
        guard let original else { return String(localized: "操作被拒绝", bundle: .module) }
        let lower = original.lowercased()
        if lower.contains("invalid link") || lower.contains("already on list") { return String(localized: "链接无效或任务已存在", bundle: .module) }
        if lower.contains("filehash not found") { return String(localized: "找不到该电驴任务", bundle: .module) }
        if lower.contains("category") { return String(localized: "无法设置下载分类，请检查保存目录", bundle: .module) }
        if lower.contains("disabled") { return String(localized: "对应的电驴网络尚未启用", bundle: .module) }
        return String(localized: "操作被拒绝（\(original)）", bundle: .module)
    }
}

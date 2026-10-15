import Foundation

enum Ed2kErrorDescriptions {
    static func status(_ value: UInt64) -> String? {
        switch value {
        case 4: "电驴文件读写失败，请检查下载目录权限（aMule 状态码 4）"
        case 5: "磁盘空间不足（aMule 状态码 5）"
        case 6: "电驴文件状态异常（aMule 状态码 6）"
        default: nil
        }
    }

    static func operation(_ original: String?) -> String {
        guard let original else { return "操作被拒绝" }
        let lower = original.lowercased()
        if lower.contains("invalid link") || lower.contains("already on list") { return "链接无效或任务已存在" }
        if lower.contains("filehash not found") { return "找不到该电驴任务" }
        if lower.contains("category") { return "无法设置下载分类，请检查保存目录" }
        if lower.contains("disabled") { return "对应的电驴网络尚未启用" }
        return "操作被拒绝（\(original)）"
    }
}

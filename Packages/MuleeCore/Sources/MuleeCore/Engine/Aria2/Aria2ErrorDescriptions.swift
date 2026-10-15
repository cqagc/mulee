import Foundation

struct Aria2ErrorDescriptions: Sendable {
    static func message(for code: String?) -> String {
        let number = code.flatMap(Int.init) ?? 0
        let description: String
        switch number {
        case 3: description = String(localized: "资源不存在", bundle: .module)
        case 6: description = String(localized: "网络错误", bundle: .module)
        case 7: description = String(localized: "恢复失败", bundle: .module)
        case 9: description = String(localized: "磁盘空间不足", bundle: .module)
        case 13: description = String(localized: "文件已存在", bundle: .module)
        case 16: description = String(localized: "文件创建失败", bundle: .module)
        case 19: description = String(localized: "域名解析失败", bundle: .module)
        case 22: description = String(localized: "服务器响应异常", bundle: .module)
        case 24: description = String(localized: "需要登录认证", bundle: .module)
        default: description = String(localized: "下载出错", bundle: .module)
        }
        return String(localized: "\(description)（aria2 错误码 \(number)）", bundle: .module)
    }
}

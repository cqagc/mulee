import Foundation

struct Aria2ErrorDescriptions: Sendable {
    static func message(for code: String?, detail: String? = nil) -> String {
        // 只提取状态码，绝不把可能带签名链接、请求头的原始错误写入历史或通知。
        if let detail, let range = detail.range(of: #"status=(401|403|404|410)\b"#, options: .regularExpression),
           let status = Int(detail[range].dropFirst(7)), let failure = HTTPDownloadFailure.classify(statusCode: status) {
            return failure.localizedDescription
        }
        let number = code.flatMap(Int.init) ?? 0
        if number == 7 { return HTTPDownloadFailure.resourceChanged.localizedDescription }
        let description: String
        switch number {
        case 3: description = String(localized: "资源不存在", bundle: .module)
        case 6: description = String(localized: "网络错误", bundle: .module)
        case 9: description = String(localized: "磁盘空间不足", bundle: .module)
        case 13: description = String(localized: "文件已存在", bundle: .module)
        case 16: description = String(localized: "文件创建失败", bundle: .module)
        case 19: description = String(localized: "域名解析失败", bundle: .module)
        case 22: description = String(localized: "服务器响应异常", bundle: .module)
        case 24: description = String(localized: "需要登录认证", bundle: .module)
        case 32: description = "校验值不一致，请重新下载"
        default: description = String(localized: "下载出错", bundle: .module)
        }
        return String(localized: "\(description)（aria2 错误码 \(number)）", bundle: .module)
    }
}

struct Aria2ErrorDescriptions: Sendable {
    static func message(for code: String?) -> String {
        let number = code.flatMap(Int.init) ?? 0
        let description: String
        switch number {
        case 3: description = "资源不存在"
        case 6: description = "网络错误"
        case 7: description = "恢复失败"
        case 9: description = "磁盘空间不足"
        case 13: description = "文件已存在"
        case 16: description = "文件创建失败"
        case 19: description = "域名解析失败"
        case 22: description = "服务器响应异常"
        case 24: description = "需要登录认证"
        default: description = "下载出错"
        }
        return "\(description)（aria2 错误码 \(number)）"
    }
}

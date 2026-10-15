import Foundation

struct TorrentErrorDescriptions: Sendable {
    static func error(for code: String) -> EngineError {
        let number: Int
        let message: String
        switch code {
        case "invalid_request": (number, message) = (1, String(localized: "BT 引擎请求格式有误", bundle: .module))
        case "unknown_method": (number, message) = (2, String(localized: "BT 引擎不支持此操作", bundle: .module))
        case "invalid_params": (number, message) = (3, String(localized: "BT 下载参数有误", bundle: .module))
        case "not_found": (number, message) = (4, String(localized: "BT 任务不存在", bundle: .module))
        case "invalid_torrent": (number, message) = (5, String(localized: "种子文件或磁力链接无效", bundle: .module))
        case "io_error": (number, message) = (6, String(localized: "无法读写下载文件，请检查磁盘空间和访问权限", bundle: .module))
        default: (number, message) = (7, String(localized: "BT 引擎出错", bundle: .module))
        }
        return .rpc(code: number, message: String(localized: "\(message)（torrentd 错误码 \(code)）", bundle: .module))
    }

    static func taskMessage(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("space") { return String(localized: "磁盘空间不足", bundle: .module) }
        if lowercased.contains("permission") || lowercased.contains("denied") { return String(localized: "没有文件访问权限", bundle: .module) }
        if lowercased.contains("no such file") { return String(localized: "下载文件不存在", bundle: .module) }
        return String(localized: "BT 下载出错，请检查保存目录和网络连接", bundle: .module)
    }
}

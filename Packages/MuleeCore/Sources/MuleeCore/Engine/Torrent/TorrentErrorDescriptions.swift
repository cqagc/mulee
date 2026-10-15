struct TorrentErrorDescriptions: Sendable {
    static func error(for code: String) -> EngineError {
        let number: Int
        let message: String
        switch code {
        case "invalid_request": (number, message) = (1, "BT 引擎请求格式有误")
        case "unknown_method": (number, message) = (2, "BT 引擎不支持此操作")
        case "invalid_params": (number, message) = (3, "BT 下载参数有误")
        case "not_found": (number, message) = (4, "BT 任务不存在")
        case "invalid_torrent": (number, message) = (5, "种子文件或磁力链接无效")
        case "io_error": (number, message) = (6, "无法读写下载文件，请检查磁盘空间和访问权限")
        default: (number, message) = (7, "BT 引擎出错")
        }
        return .rpc(code: number, message: "\(message)（torrentd 错误码 \(code)）")
    }

    static func taskMessage(_ message: String) -> String {
        let lowercased = message.lowercased()
        if lowercased.contains("space") { return "磁盘空间不足" }
        if lowercased.contains("permission") || lowercased.contains("denied") { return "没有文件访问权限" }
        if lowercased.contains("no such file") { return "下载文件不存在" }
        return "BT 下载出错，请检查保存目录和网络连接"
    }
}

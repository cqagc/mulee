import Foundation
import MuleeCore

/// 随草稿传递，密码只在内存中保留，不参与任务编码。
struct NewTaskContext {
    var sourcePageURL: URL?
    var password: String?
    var requestContext = DownloadRequestContext()
    var videoFormatID: String?
    var videoFormatVideoOnly = false
    var checksum: DownloadChecksum?
}

/// 仅保存在内存中；下一个匹配交接消耗等待状态。
struct HTTPReplacementWait {
    let taskID: UUID
    let host: String?
    let filename: String
    let expiresAt: Date
}

struct BrowserHTTPReplacement {
    let id = UUID()
    let taskID: UUID
    let url: URL
    let context: DownloadRequestContext
}

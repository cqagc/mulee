import Foundation

/// 随草稿传递，密码只在内存中保留，不参与任务编码。
struct NewTaskContext {
    var sourcePageURL: URL?
    var password: String?
}

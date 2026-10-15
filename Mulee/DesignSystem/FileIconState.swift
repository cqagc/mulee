import MuleeCore

/// 文件落盘前是虚线，落盘后是实心；进度只表示已收到的文件数据。
enum FileIconState: Equatable, Sendable {
    case downloading(progress: Double)
    case completed
    case attention(progress: Double)
    case engineUnavailable(progress: Double)

    init(status: TaskStatus, progress: Double?) {
        let progress = progress ?? 0
        switch status {
        case .downloading, .queued, .paused:
            self = .downloading(progress: progress)
        case .completed, .extracting, .postProcessing, .seeding:
            self = .completed
        case .failed, .waitingForSources:
            self = .attention(progress: progress)
        case .engineUnavailable:
            self = .engineUnavailable(progress: progress)
        }
    }

    init(task: DownloadTask) {
        self.init(status: task.status, progress: task.fractionCompleted)
    }

    var progress: Double {
        let value: Double
        switch self {
        case .completed: value = 1
        case .downloading(let progress), .attention(let progress), .engineUnavailable(let progress): value = progress
        }
        return value.isFinite ? min(1, max(0, value)) : 0
    }

    var isCompleted: Bool { self == .completed }

    var needsAttention: Bool {
        if case .attention = self { return true }
        return false
    }

    var isEngineUnavailable: Bool {
        if case .engineUnavailable = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .downloading: "下载中"
        case .completed: "已完成"
        case .attention: "需要注意"
        case .engineUnavailable: "引擎未接入"
        }
    }
}

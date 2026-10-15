import MuleeCore

/// UI 可观察的引擎状态；未接入的类型不会伪装成正在下载。
enum EngineState: Equatable, Sendable {
    case running
    case preparing
    case missingFFmpeg
    case unavailable
    case failed(String)
}

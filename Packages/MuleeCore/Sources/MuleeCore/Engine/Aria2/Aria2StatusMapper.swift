import Foundation

struct Aria2StatusMapper: Sendable {
    static func snapshot(_ value: Aria2RPCModels.Status) -> EngineTaskSnapshot? {
        let status: TaskStatus
        switch value.status {
        case "active": status = .downloading
        case "waiting": status = .queued
        case "paused": status = .paused
        case "complete": status = .completed
        case "error": status = .failed
        default: return nil
        }
        let file = value.files?.first
        let source = file?.uris?.first.flatMap { URL(string: $0.uri) }
        let path = file.flatMap { $0.path.isEmpty ? nil : URL(fileURLWithPath: $0.path) }
        // URL.lastPathComponent already decodes percent escapes exactly once.
        let inferredName = path?.lastPathComponent ?? source?.lastPathComponent ?? ""
        let name = (inferredName.isEmpty || inferredName == "/") ? String(localized: "下载文件", bundle: .module) : inferredName
        let total = Int64(value.totalLength ?? "0") ?? 0
        return EngineTaskSnapshot(
            engineTaskID: value.gid, name: name, totalBytes: total > 0 ? total : nil,
            receivedBytes: Int64(value.completedLength ?? "0") ?? 0,
            downloadRate: Int64(value.downloadSpeed ?? "0") ?? 0,
            uploadRate: Int64(value.uploadSpeed ?? "0") ?? 0,
            status: status, connections: Int(value.connections ?? "0") ?? 0,
            savePath: path, sourceURL: source,
            errorMessage: status == .failed ? Aria2ErrorDescriptions.message(for: value.errorCode, detail: value.errorMessage) : nil
        )
    }
}

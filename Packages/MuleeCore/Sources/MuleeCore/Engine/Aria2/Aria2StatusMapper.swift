import Foundation

struct Aria2StatusMapper: Sendable {
    static func snapshot(_ value: Aria2RPCModels.Status, diagnosticLog: String = "") -> EngineTaskSnapshot? {
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
        let detail = value.errorMessage ?? ""
        var writesFailed = ["9", "16", "17"].contains(value.errorCode ?? "") || EngineTaskSnapshot.describesFileWriteFailure(detail)
        var controlFailed = controlFileFailure(detail)
        if value.errorCode == "1" {
            if let flags = fileFailure(in: diagnosticLog, source: source?.absoluteString, path: path?.path) {
                writesFailed = flags.write
                controlFailed = flags.control
            } else if detail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "download aborted." {
                // aria2 可能尚未刷出异常链，先保留卸载检测的宽限期。
                writesFailed = true
            }
        }
        return EngineTaskSnapshot(
            engineTaskID: value.gid, name: name, totalBytes: total > 0 ? total : nil,
            receivedBytes: Int64(value.completedLength ?? "0") ?? 0,
            downloadRate: Int64(value.downloadSpeed ?? "0") ?? 0,
            uploadRate: Int64(value.uploadSpeed ?? "0") ?? 0,
            status: status, connections: Int(value.connections ?? "0") ?? 0,
            savePath: path, sourceURL: source,
            errorMessage: status == .failed ? Aria2ErrorDescriptions.message(for: value.errorCode, detail: value.errorMessage) : nil,
            isFileWriteFailure: status == .failed && writesFailed,
            isControlFileFailure: status == .failed && controlFailed
        )
    }
    private static func controlFileFailure(_ detail: String) -> Bool {
        let lower = detail.lowercased()
        return ["control file", "ctrl file", "failed to load segment file", "reading segment file"].contains(where: lower.contains)
    }

    /// RPC 的错误码 1 常只给出 Download aborted；按来源或路径关联同一次异常链，只返回分类。
    static func fileFailure(in log: String, source: String?, path: String?) -> (write: Bool, control: Bool)? {
        var blocks: [String] = []
        for line in log.components(separatedBy: .newlines) {
            if line.first?.isNumber == true, line.contains("[ERROR]") {
                blocks.append(line)
            } else if !blocks.isEmpty {
                blocks[blocks.count - 1] += "\n" + line
            }
        }
        for block in blocks.reversed() {
            let sourceMatches = source.map { block.components(separatedBy: .newlines).first?.hasSuffix("URI=" + $0) == true } ?? false
            let pathMatches = path.map { !$0.isEmpty && block.contains($0) } ?? false
            guard sourceMatches || pathMatches else { continue }
            let control = controlFileFailure(block)
            return (EngineTaskSnapshot.describesFileWriteFailure(block) || control, control)
        }
        return nil
    }

}

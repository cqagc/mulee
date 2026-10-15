import AppKit
import MuleeCore
import UniformTypeIdentifiers

/// 链接文字和 URL 采用同一条预填路径，保留一次拖入的顺序。
enum OpenURLDropHandler {
    static let types = [UTType.fileURL, .url, .plainText]

    static func accept(_ providers: [NSItemProvider], model: AppModel) -> Bool {
        let supported = providers.filter { provider in
            types.contains { provider.hasItemConformingToTypeIdentifier($0.identifier) }
        }
        guard !supported.isEmpty else { return false }
        Task {
            var texts: [String] = []
            for provider in supported {
                guard let type = types.first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { continue }
                do {
                    let data: Data = try await withCheckedThrowingContinuation { continuation in
                        provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                            if let data { continuation.resume(returning: data) }
                            else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
                        }
                    }
                    guard let text = String(data: data, encoding: .utf8) else { continue }
                    let links = LinkParser.parse(text)
                    texts += links.map(\.original)
                } catch {
                    model.openURLIssue = "无法读取拖入的链接：\(error.localizedDescription)"
                }
            }
            if !texts.isEmpty { model.showNewTask(prefill: texts.joined(separator: "\n")) }
        }
        return true
    }
}

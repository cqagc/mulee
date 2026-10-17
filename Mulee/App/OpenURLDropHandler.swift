import AppKit
import MuleeCore
import UniformTypeIdentifiers

/// 菜单栏、原生主窗口和新建面板共用文件读取与链接识别，保持拖入顺序。
enum OpenURLDropHandler {
    static let types = [UTType.fileURL, .url, .plainText]
    static let pasteboardTypes: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string]

    nonisolated static func text(from value: Any) -> String? {
        if let url = value as? URL { return NewTaskModel.droppedURLText(url) }
        if let data = value as? Data, let text = String(data: data, encoding: .utf8) {
            return NewTaskModel.droppedText(text)
        }
        if let text = value as? String { return NewTaskModel.droppedText(text) }
        return nil
    }

    static func text(from pasteboard: NSPasteboard) -> String? {
        let texts = (pasteboard.pasteboardItems ?? []).compactMap { item -> String? in
            for type in pasteboardTypes {
                if let value = item.string(forType: type), let text = text(from: value as Any) { return text }
            }
            return nil
        }
        return texts.isEmpty ? nil : texts.joined(separator: "\n")
    }

    @discardableResult
    static func accept(_ pasteboard: NSPasteboard, model: AppModel) -> Bool {
        guard let text = text(from: pasteboard) else { return false }
        for item in pasteboard.pasteboardItems ?? [] {
            if let file = item.string(forType: .fileURL) {
                registerFinderTorrents(file, model: model)
            }
        }
        model.showNewTask(prefill: text)
        return true
    }

    private static func registerFinderTorrents(_ text: String, model: AppModel) {
        for parsed in SmartPasteParser.parse(text).flatMap(\.links) where OpenURLRouter.isLocalTorrent(parsed) {
            guard case .torrentFile(let url, _) = parsed else { continue }
            let link = ParsedLink.torrentFile(url: url, original: url.absoluteString)
            var context = model.pendingNewTaskContexts[link] ?? NewTaskContext()
            context.finderTorrent = true
            model.pendingNewTaskContexts[link] = context
        }
    }

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
                    let text: String? = try await withCheckedThrowingContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { value, error in
                            if let error { continuation.resume(throwing: error) }
                            else { continuation.resume(returning: value.flatMap { Self.text(from: $0) }) }
                        }
                    }
                    if let text {
                        if type == .fileURL { registerFinderTorrents(text, model: model) }
                        texts.append(text)
                    }
                } catch {
                    model.openURLIssue = String(localized: "无法读取拖入的链接：\(error.localizedDescription)")
                }
            }
            if !texts.isEmpty {
                let text = texts.joined(separator: "\n")
                model.showNewTask(prefill: text)
            }
        }
        return true
    }
}

import AppKit
import MuleeCore
import UniformTypeIdentifiers
import SwiftUI

/// 列表菜单和详情栏共用的系统操作。
enum TaskActions {
    @ViewBuilder
    static func relinkTorrentButton(_ task: DownloadTask, model: AppModel) -> some View {
        Button("重新关联…", systemImage: "link") {
            relinkTorrent(task, model: model)
        }
        .disabled(task.deletedAt != nil || task.engineTaskID == nil)
    }

    @ViewBuilder
    static func redownloadTorrentButton(_ task: DownloadTask, model: AppModel) -> some View {
        Button("重新下载", systemImage: MuleeSymbol.retry.name) {
            confirmRedownload(task, model: model)
        }
        .disabled(task.deletedAt != nil || model.redownloadingIDs.contains(task.id))
    }

    @MainActor
    private static func relinkTorrent(_ task: DownloadTask, model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "重新关联")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                guard let coordinator = model.coordinator else { throw EngineError.notRunning }
                try await coordinator.relinkTorrent(task.id, to: url)
            }
            catch { showTorrentError(error) }
        }
    }

    @MainActor
    private static func confirmRedownload(_ task: DownloadTask, model: AppModel) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "重新下载「\(task.name)」？")
        alert.informativeText = String(localized: "这会清除当前任务的已完成状态，并按原始种子重新校验或下载。")
        alert.addButton(withTitle: String(localized: "取消"))
        alert.addButton(withTitle: String(localized: "重新下载"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task { await model.redownloadMissingFile(task.id) }
    }
    static func moveTorrentStorage(_ task: DownloadTask, model: AppModel) {
        guard task.needsFileRelink != true else { return }
        guard let controller = model.bitTorrent, let id = task.engineTaskID else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "移动到此处")
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        Task {
            do {
                do {
                    try await controller.engine.moveStorage(id, to: directory)
                } catch EngineError.rpc(code: 11, message: _) {
                    let alert = NSAlert()
                    alert.messageText = String(localized: "目标位置已有同名文件")
                    alert.informativeText = String(localized: "保留会使用目标文件并重新校验；覆盖会替换目标文件。")
                    alert.addButton(withTitle: String(localized: "取消"))
                    alert.addButton(withTitle: String(localized: "保留目标文件"))
                    alert.addButton(withTitle: String(localized: "覆盖目标文件"))
                    let response = alert.runModal()
                    guard response == .alertSecondButtonReturn || response == .alertThirdButtonReturn else { return }
                    try await controller.engine.moveStorage(
                        id, to: directory, conflict: response == .alertSecondButtonReturn ? .keep : .overwrite
                    )
                }
                await model.coordinator?.poll()
            } catch {
                showTorrentError(error)
            }
            await controller.refreshTaskLocation(id)
        }
    }

    static func recheckTorrent(_ task: DownloadTask, model: AppModel) {
        guard let engine = model.bitTorrent?.engine, let id = task.engineTaskID else { return }
        Task {
            do { try await engine.forceRecheck(id) }
            catch { showTorrentError(error) }
        }
    }

    static func reannounceTorrent(_ task: DownloadTask, model: AppModel) {
        guard let engine = model.bitTorrent?.engine, let id = task.engineTaskID else { return }
        Task {
            do { try await engine.forceReannounce(id) }
            catch { showTorrentError(error) }
        }
    }

    static func exportTorrent(_ task: DownloadTask, model: AppModel) {
        guard let engine = model.bitTorrent?.engine, let id = task.engineTaskID else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = task.name + ".torrent"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        Task {
            do {
                _ = try await engine.exportTorrent(id, to: output)
                NSWorkspace.shared.activateFileViewerSelecting([output])
            } catch { showTorrentError(error) }
        }
    }

    private static func showTorrentError(_ error: any Error) {
        let alert = NSAlert()
        alert.messageText = String(localized: "BT 操作未完成")
        alert.informativeText = EngineStatusPresentation.errorMessage(error)
        alert.addButton(withTitle: String(localized: "好"))
        alert.runModal()
    }

    @MainActor
    static func editTags(_ task: DownloadTask, model: AppModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "编辑标签")
        alert.informativeText = String(localized: "用逗号分隔多个标签；清空可移除全部标签。")
        let field = NSTextField(string: (task.tags ?? []).joined(separator: ", "))
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.setAccessibilityLabel(String(localized: "标签"))
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "保存"))
        let cancel = alert.addButton(withTitle: String(localized: "取消"))
        alert.window.defaultButtonCell = cancel.cell as? NSButtonCell
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { model.setTags(task.id, text: field.stringValue) }
    }

    static func canCopyMagnet(_ task: DownloadTask) -> Bool {
        task.kind == .bittorrent && task.engineTaskID != nil
    }

    static func copiesMagnetForSource(_ task: DownloadTask) -> Bool {
        task.kind == .bittorrent && URL(string: task.sourceLink)?.isFileURL == true
    }

    static func copyLink(_ task: DownloadTask, model: AppModel) {
        if copiesMagnetForSource(task) {
            copyMagnet(task, model: model)
        } else {
            _ = SystemClipboard.write(task.sourceLink)
        }
    }

    static func copyMagnet(_ task: DownloadTask, model: AppModel) {
        Task {
            do {
                guard let engine = model.bitTorrent?.engine, let id = task.engineTaskID else { throw EngineError.notRunning }
                let uri = try await engine.magnetURI(id)
                guard uri.hasPrefix("magnet:?"), SystemClipboard.write(uri) else { throw CocoaError(.fileWriteUnknown) }
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "无法复制磁力链接")
                alert.informativeText = String(localized: "请等待种子信息读取完成，并确认 BT 引擎已连接后重试。")
                alert.addButton(withTitle: String(localized: "好"))
                alert.runModal()
            }
        }
    }

    static func localURL(for task: DownloadTask) -> URL {
        task.savePath ?? URL.downloadsDirectory.appending(path: "Mulee", directoryHint: .isDirectory)
            .appending(path: task.name, directoryHint: .inferFromPath)
    }

    enum OpenAction: Equatable {
        case open(URL)
        case reveal(URL)
    }

    static func openAction(for task: DownloadTask, defaultDirectory: URL) -> OpenAction? {
        guard task.deletedAt == nil else { return nil }
        var tracked = task
        if tracked.fileBookmark != nil { FileTracker.resolve(&tracked) }

        let manager = FileManager.default
        let path = tracked.savePath
        if tracked.fileMissing != true, let path, path.isFileURL, manager.fileExists(atPath: path.path),
           let info = try? path.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey, .contentTypeKey]) {
            if info.contentType?.conforms(to: .application) == true { return .reveal(path) }
            if info.isDirectory == true && info.isPackage != true { return .open(path) }
            if tracked.status == .completed || tracked.status == .seeding { return .open(path) }
            return .reveal(path)
        }

        // 元数据尚未就绪或文件已移走时，打开仍可用的保存目录。
        let directories = [path?.deletingLastPathComponent()].compactMap { $0 }
            + (task.writeDirectories ?? []) + [defaultDirectory, .downloadsDirectory]
        for directory in directories where directory.isFileURL {
            var isDirectory: ObjCBool = false
            if manager.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue {
                return .open(directory)
            }
        }
        return nil
    }

    static func openDownload(_ task: DownloadTask, defaultDirectory: URL) {
        switch openAction(for: task, defaultDirectory: defaultDirectory) {
        case .open(let url):
            if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .reveal(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
        case nil:
            break
        }
    }

    static func reveal(_ task: DownloadTask) {
        let url = localURL(for: task)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            let directory = task.savePath?.deletingLastPathComponent()
                ?? URL.downloadsDirectory.appending(path: "Mulee", directoryHint: .isDirectory)
            NSWorkspace.shared.open(task.savePath != nil || FileManager.default.fileExists(atPath: directory.path) ? directory : .downloadsDirectory)
        }
    }
}

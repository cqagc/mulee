import AppKit
import MuleeCore

/// 列表菜单和详情栏共用的系统操作。
enum TaskActions {
    static func moveTorrentStorage(_ task: DownloadTask, model: AppModel) {
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
        alert.addButton(withTitle: String(localized: "取消"))
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { model.setTags(task.id, text: field.stringValue) }
    }

    static func copyLink(_ task: DownloadTask) {
        _ = SystemClipboard.write(task.sourceLink)
    }

    static func localURL(for task: DownloadTask) -> URL {
        task.savePath ?? URL.downloadsDirectory.appending(path: "Mulee", directoryHint: .isDirectory)
            .appending(path: task.name, directoryHint: .inferFromPath)
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

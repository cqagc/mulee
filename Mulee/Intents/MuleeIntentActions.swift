import Foundation
import MuleeCore

@MainActor
final class MuleeIntentActions {
    enum ValidationError: LocalizedError {
        case invalidLink
        case invalidDirectory
        case playlistSelectionRequired

        var errorDescription: String? {
            switch self {
            case .invalidLink: String(localized: "请输入一个有效的下载链接。")
            case .invalidDirectory: String(localized: "保存目录必须是本机的绝对目录路径。")
            case .playlistSelectionRequired: String(localized: "播放列表需要在新建面板里选择要下载的集")
            }
        }
    }

    struct Status: Equatable {
        var downloadingCount: Int
        var downloadRate: Int64
        var uploadRate: Int64
        var latestCompletedName: String?

        var summary: String {
            let download = ByteCountFormatter.string(fromByteCount: downloadRate, countStyle: .file)
            let upload = ByteCountFormatter.string(fromByteCount: uploadRate, countStyle: .file)
            let name = latestCompletedName ?? String(localized: "暂无")
            return String(localized: "正在下载：\(downloadingCount)；下载速度：\(download)/s；上传速度：\(upload)/s；最近完成：\(name)")
        }
    }

    private let model: AppModel

    init(model: AppModel) {
        self.model = model
    }

    static func validate(link: String, directory: String?) throws -> (link: ParsedLink, directory: URL?) {
        let text = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let links = LinkParser.parse(text)
        guard !text.isEmpty, text.utf8.count <= OpenURLRequest.maximumBytes,
              !text.contains("\n"), !text.contains("\r"), links.count == 1,
              let parsed = links.first, OpenURLRequest.isRemote(parsed) else { throw ValidationError.invalidLink }
        var destination: URL?
        if let directory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = (directory.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
            guard path.hasPrefix("/"), !path.contains("\0") else { throw ValidationError.invalidDirectory }
            destination = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
        }
        return (parsed, destination)
    }

    func prefill(link: String, directory: String?, canPresentNewTask: Bool = true) throws {
        let request = try Self.validate(link: link, directory: directory)
        if AppModel.isPureVideoPlaylist(request.link), !canPresentNewTask {
            throw ValidationError.playlistSelectionRequired
        }
        model.pendingNewTaskDirectory = request.directory
        model.showNewTask(prefill: request.link.original)
    }

    func pauseAll() {
        model.pauseAll()
    }

    func resumeAll() {
        model.resumeAll()
    }

    func status() -> Status {
        let tasks = model.activeTasks
        let latest = tasks.filter { $0.completedAt != nil }.max { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
        return Status(
            downloadingCount: tasks.filter { $0.status == .downloading }.count,
            downloadRate: model.totalDownloadRate, uploadRate: model.totalUploadRate, latestCompletedName: latest?.name
        )
    }
}

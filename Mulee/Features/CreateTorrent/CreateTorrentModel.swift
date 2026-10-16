import Foundation
import MuleeCore
import Observation

@Observable
final class CreateTorrentModel {
    typealias Creator = (URL, URL, Bool, [String], @escaping @Sendable (TorrentCreationProgress) async -> Void) async throws -> Void

    var source: URL?
    var trackerText = ""
    var isPrivate = false
    var startsSeeding = false
    private(set) var isWorking = false
    private(set) var output: URL?
    private(set) var issue: String?
    private(set) var progress: TorrentCreationProgress?
    private(set) var job: Task<Void, Never>?
    private var activeJob: UUID?

    var trackers: [String] {
        trackerText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var validation: String? { BitTorrentManagementModel.trackerValidation(trackers) }

    func start(to destination: URL, creator: @escaping Creator, seed: @escaping (URL, URL) async throws -> Void) {
        guard let source, !isWorking, validation == nil else { return }
        let resolvedSource = resolvingExistingAncestors(of: source)
        let resolvedDestination = resolvingExistingAncestors(of: destination)
        var isDirectory: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: resolvedSource.path, isDirectory: &isDirectory)
        let sourceComponents = resolvedSource.pathComponents
        if resolvedDestination.path == resolvedSource.path
            || (isDirectory.boolValue && resolvedDestination.pathComponents.starts(with: sourceComponents)) {
            issue = String(localized: "保存位置与源文件相同或位于源文件夹内。制作已停止，以免覆盖原文件或把种子算入内容。请选择源文件夹外的 .torrent 保存位置。")
            return
        }
        let token = UUID()
        activeJob = token
        isWorking = true
        output = nil
        issue = nil
        progress = nil
        let trackers = trackers
        let privateTorrent = isPrivate
        let shouldSeed = startsSeeding
        // 取消传播到引擎；RPC 确认哈希退出后再清理临时目录。
        job = Task {
            guard activeJob == token else { return }
            let manager = FileManager.default
            let temporaryDirectory = destination.deletingLastPathComponent()
                .appending(path: ".mulee-create-" + UUID().uuidString, directoryHint: .isDirectory)
            let temporaryOutput = temporaryDirectory.appending(path: "created.torrent")
            defer {
                try? manager.removeItem(at: temporaryDirectory)
                if activeJob == token { isWorking = false }
            }
            do {
                try manager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
                try await creator(source, temporaryOutput, privateTorrent, trackers) { [weak self] progress in
                    await self?.updateProgress(progress, token: token)
                }
                guard activeJob == token else { return }
                if let progress {
                    self.progress = TorrentCreationProgress(
                        completedPieces: progress.totalPieces, totalPieces: progress.totalPieces,
                        processedBytes: progress.totalBytes, totalBytes: progress.totalBytes
                    )
                }
                // moveItem 不覆盖已有输出，避免生成期间其他进程写入的文件被替换。
                try manager.moveItem(at: temporaryOutput, to: destination)
                output = destination
                if shouldSeed { try await seed(destination, source.deletingLastPathComponent()) }
            } catch {
                guard activeJob == token else { return }
                issue = output == nil
                    ? String(localized: "制作未完成：\(EngineStatusPresentation.errorMessage(error))。请检查输入和保存位置后重试。")
                    : String(localized: "种子已保存，但做种未开始。请通过新建下载添加此种子，并选择原文件所在目录。")
            }
        }
    }

    func cancel() {
        activeJob = nil
        isWorking = false
        job?.cancel()
    }

    private func resolvingExistingAncestors(of url: URL) -> URL {
        var existing = url
        var missingComponents: [String] = []
        // 新输出还不存在时，直接 resolvingSymlinksInPath 不会解析父目录里的符号链接。
        while !FileManager.default.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else { break }
            missingComponents.append(existing.lastPathComponent)
            existing = parent
        }
        return missingComponents.reversed().reduce(existing.resolvingSymlinksInPath()) {
            $0.appendingPathComponent($1)
        }.standardizedFileURL
    }

    private func updateProgress(_ progress: TorrentCreationProgress, token: UUID) {
        guard activeJob == token else { return }
        self.progress = progress
    }
}

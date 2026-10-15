import Foundation
import MuleeCore
import Observation

/// 仅在详情栏显示该 BT 任务期间轮询，切换任务即取消。
@Observable
final class BitTorrentFilesModel {
    private(set) var files: [TorrentFileEntry] = []
    private(set) var info: TorrentTaskInfo?
    private(set) var isUpdating = false
    var issue: String?
    private var revision = 0
    private var currentID: String?
    private var engine: TorrentEngine?

    var selectedCount: Int { files.filter { $0.priority > 0 }.count }

    func watch(engine: TorrentEngine?, id: String?) async {
        revision += 1
        currentID = id
        self.engine = engine
        files = []
        info = nil
        issue = nil
        guard let engine, let id else { return }
        while !Task.isCancelled {
            let currentRevision = revision
            do {
                let entries = try await engine.files(id)
                let details = try await engine.taskInfo(id)
                guard !Task.isCancelled, currentID == id else { return }
                if !isUpdating, revision == currentRevision {
                    files = entries
                    info = details
                    issue = nil
                }
            } catch {
                guard !Task.isCancelled, currentID == id else { return }
                issue = EngineStatusPresentation.errorMessage(error)
            }
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
        }
    }

    static func priorities(
        for files: [TorrentFileEntry], index: Int, selected: Bool
    ) -> [Int]? {
        guard files.contains(where: { $0.index == index }) else { return nil }
        let priorities = files.map { $0.index == index ? (selected ? 4 : 0) : $0.priority }
        return priorities.contains(where: { $0 > 0 }) ? priorities : nil
    }

    func setSelected(_ selected: Bool, file: TorrentFileEntry) async {
        guard !isUpdating, let engine, let id = currentID,
              let priorities = Self.priorities(for: files, index: file.index, selected: selected) else { return }
        isUpdating = true
        revision += 1
        defer {
            isUpdating = false
            revision += 1
        }
        do {
            try await engine.setFilePriorities(id, priorities)
            let entries = try await engine.files(id)
            guard currentID == id, !Task.isCancelled else { return }
            files = entries
            issue = nil
        } catch {
            guard currentID == id else { return }
            issue = EngineStatusPresentation.errorMessage(error)
        }
    }
}

import Foundation

struct TorrentStatusMapper: Sendable {
    static func status(state: String, paused: Bool, queued: Bool, completed: Bool) -> TaskStatus {
        if paused { return completed ? .completed : .paused }
        switch state {
        case "checking", "metadata": return .downloading
        case "downloading": return queued ? .queued : .downloading
        case "seeding": return .seeding
        case "finished": return .completed
        default: return .failed
        }
    }

    static func snapshot(_ value: TorrentdTask) -> EngineTaskSnapshot {
        let completed = value.state == "finished" || value.state == "seeding"
            || (value.hasMetadata && value.totalWantedDone >= value.totalWanted)
        let status = status(state: value.state, paused: value.paused, queued: value.queued, completed: completed)
        let source = value.source.flatMap { text in
            text.hasPrefix("/") ? URL(fileURLWithPath: text) : URL(string: text)
        }
        return EngineTaskSnapshot(
            engineTaskID: value.id, name: value.name,
            totalBytes: value.hasMetadata ? value.totalWanted : nil,
            receivedBytes: value.totalWantedDone,
            downloadRate: value.downloadRate, uploadRate: value.uploadRate,
            status: status, connections: value.numPeers,
            savePath: value.contentPath.map { URL(fileURLWithPath: $0) }, sourceURL: source,
            errorMessage: status == .failed ? TorrentErrorDescriptions.taskMessage(value.error ?? "") : nil,
            detail: .bittorrent(
                fileCount: value.fileCount, selectedFileCount: value.selectedFileCount,
                peerCount: value.numPeers, shareRatio: value.ratio
            ),
            completedAt: value.completedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }
}

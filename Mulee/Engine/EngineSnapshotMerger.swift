import Foundation
import MuleeCore

/// 只合并本次成功取得的引擎快照；终态历史不依赖引擎会话。
enum EngineSnapshotMerger {
    static func merge(
        tasks: [DownloadTask],
        snapshots: [TaskKind: [EngineTaskSnapshot]],
        now: Date,
        videoConfiguration: VideoEngineConfiguration = VideoEngineConfiguration()
    ) -> [DownloadTask] {
        var result = tasks.map { task in
            guard let id = task.engineTaskID, let current = snapshots[task.kind],
                  !current.contains(where: { $0.engineTaskID == id }),
                  [.downloading, .queued, .paused].contains(task.status) else { return task }
            var task = task
            task.status = .failed
            task.errorMessage = "上次退出前的进度没能恢复，可以重新下载"
            task.downloadRate = 0
            task.uploadRate = 0
            task.estimatedTimeRemaining = nil
            return task
        }
        for kind in TaskKind.allCases {
            for snapshot in snapshots[kind] ?? [] {
                let index = result.firstIndex { $0.kind == kind && $0.engineTaskID == snapshot.engineTaskID }
                var task: DownloadTask
                if let index {
                    task = result[index]
                } else {
                    task = DownloadTask(
                        name: snapshot.name,
                        fileExtension: nil,
                        kind: kind,
                        status: .queued,
                        totalBytes: nil,
                        receivedBytes: 0,
                        detail: defaultDetail(for: kind, now: now),
                        postDownload: PostDownloadInfo(autoExtract: false),
                        sourceLink: snapshot.sourceURL?.absoluteString ?? "",
                        engineTaskID: snapshot.engineTaskID
                    )
                    if kind == .video, let url = snapshot.sourceURL,
                       let link = LinkParser.parse(url.absoluteString).first,
                       let detail = videoConfiguration.detail(for: link) {
                        task.detail = detail
                    }
                }
                task.name = snapshot.name
                let pathExtension = URL(filePath: snapshot.name).pathExtension
                task.fileExtension = pathExtension.isEmpty ? nil : pathExtension
                task.totalBytes = snapshot.totalBytes
                task.receivedBytes = snapshot.receivedBytes
                task.downloadRate = snapshot.downloadRate
                task.uploadRate = snapshot.uploadRate
                task.status = snapshot.status
                task.savePath = snapshot.savePath
                task.errorMessage = snapshot.errorMessage
                if kind == .http {
                    task.detail = .http(connections: snapshot.connections)
                }
                if let total = snapshot.totalBytes, snapshot.downloadRate > 0, snapshot.status == .downloading {
                    task.estimatedTimeRemaining = .seconds(Double(max(0, total - snapshot.receivedBytes)) / Double(snapshot.downloadRate))
                } else {
                    task.estimatedTimeRemaining = nil
                }
                if snapshot.status == .completed, task.completedAt == nil {
                    task.completedAt = now
                }
                if let index {
                    result[index] = task
                } else {
                    result.append(task)
                }
            }
        }
        return result
    }

    static func appendingRate(_ rate: Int64, to history: [Int64]) -> [Int64] {
        Array((history + [rate]).suffix(30))
    }

    private static func defaultDetail(for kind: TaskKind, now: Date) -> TaskDetail {
        switch kind {
        case .http: .http(connections: 0)
        case .bittorrent: .bittorrent(fileCount: 0, selectedFileCount: 0, peerCount: 0, shareRatio: 0)
        case .ed2k:
            .ed2k(hash: "", longTail: LongTailInfo(
                queueRank: nil, sourceCount: 0, completeSourceCount: 0,
                lastCompleteSourceSeen: nil, waitingSince: now,
                activeTransferDuration: .zero, dailySourceSightings: []
            ))
        case .video: .video(site: .other, quality: "自动", danmakuToASS: false)
        }
    }
}

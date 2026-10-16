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
        // 按引擎任务标识建索引：上万条任务时逐条线性查找是平方级开销，每秒轮询会卡住主线程。
        let snapshotIDs = snapshots.mapValues { Set($0.map(\.engineTaskID)) }
        var result = tasks.map { task in
            guard task.deletedAt == nil, let id = task.engineTaskID, let current = snapshotIDs[task.kind],
                  !current.contains(id),
                  [.downloading, .queued, .paused].contains(task.status) else { return task }
            var task = task
            task.status = .failed
            task.pauseReason = nil
            task.errorMessage = String(localized: "上次退出前的进度没能恢复，可以重新下载")
            task.downloadRate = 0
            task.uploadRate = 0
            task.estimatedTimeRemaining = nil
            return task
        }
        var indexByKey: [TaskKey: Int] = [:]
        for (index, task) in result.enumerated() {
            guard let id = task.engineTaskID else { continue }
            let key = TaskKey(kind: task.kind, engineTaskID: id)
            if indexByKey[key] == nil { indexByKey[key] = index }
        }
        for kind in TaskKind.allCases {
            for snapshot in snapshots[kind] ?? [] {
                let index = indexByKey[TaskKey(kind: kind, engineTaskID: snapshot.engineTaskID)]
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
                if task.deletedAt != nil { continue }
                if task.lastProgressAt == nil || task.receivedBytes != snapshot.receivedBytes
                    || (task.status != .downloading && snapshot.status == .downloading) {
                    task.lastProgressAt = now
                }
                task.name = snapshot.name
                let pathExtension = URL(filePath: snapshot.name).pathExtension
                task.fileExtension = pathExtension.isEmpty ? nil : pathExtension
                // 暂停后的做种快照会报告完成；仅按合并前的完成进度保留计划暂停。
                let keepsScheduledSeedPause = kind == .bittorrent && task.pauseReason == .schedule
                    && ([.seeding, .completed].contains(task.status)
                        || task.totalBytes.map { $0 > 0 && task.receivedBytes >= $0 } == true)
                    && [.completed, .seeding].contains(snapshot.status)
                task.totalBytes = snapshot.totalBytes
                task.receivedBytes = snapshot.receivedBytes
                let isExtractionPause = task.pauseReason == .diskSpace && task.postDownload.extractionState == .queued
                if !isExtractionPause, !keepsScheduledSeedPause, [.completed, .seeding, .failed].contains(snapshot.status) {
                    task.pauseReason = nil
                }
                task.downloadRate = snapshot.downloadRate
                task.uploadRate = snapshot.uploadRate
                if task.pauseReason != nil {
                    task.downloadRate = 0
                    task.uploadRate = 0
                }
                // 引擎快照可能仍在报告旧状态，保护原因由应用持有。
                task.status = task.pauseReason != nil ? .paused : snapshot.status
                if task.fileBookmark == nil { task.savePath = snapshot.savePath }
                if let directories = snapshot.writeDirectories { task.writeDirectories = directories }
                task.errorMessage = snapshot.errorMessage
                if kind == .http {
                    task.detail = .http(connections: snapshot.connections)
                }
                if let detail = snapshot.detail {
                    task.detail = detail
                }
                if let total = snapshot.totalBytes, snapshot.downloadRate > 0, snapshot.status == .downloading {
                    task.estimatedTimeRemaining = .seconds(Double(max(0, total - snapshot.receivedBytes)) / Double(snapshot.downloadRate))
                } else {
                    task.estimatedTimeRemaining = nil
                }
                if let completedAt = snapshot.completedAt {
                    task.completedAt = completedAt
                } else if snapshot.status == .completed, task.completedAt == nil {
                    task.completedAt = now
                }
                if let index {
                    result[index] = task
                } else {
                    indexByKey[TaskKey(kind: kind, engineTaskID: snapshot.engineTaskID)] = result.count
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

    private struct TaskKey: Hashable {
        let kind: TaskKind
        let engineTaskID: String
    }
}

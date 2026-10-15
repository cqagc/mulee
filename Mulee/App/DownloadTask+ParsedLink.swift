import Foundation
import MuleeCore

extension DownloadTask {
    /// 用识别出的链接创建一个刚加入队列的任务。
    init(link: ParsedLink, autoExtract: Bool) {
        let postDownload = PostDownloadInfo(autoExtract: autoExtract)
        switch link {
        case .magnet(let infoHash, let displayName, let original):
            self.init(
                name: displayName ?? infoHash,
                fileExtension: nil,
                kind: .bittorrent,
                status: .downloading,
                totalBytes: nil,
                receivedBytes: 0,
                detail: .bittorrent(fileCount: 0, selectedFileCount: 0, peerCount: 0, shareRatio: 0),
                postDownload: postDownload,
                sourceLink: original
            )
        case .torrentFile(let url, let original):
            self.init(
                name: url.lastPathComponent,
                fileExtension: nil,
                kind: .bittorrent,
                status: .downloading,
                totalBytes: nil,
                receivedBytes: 0,
                detail: .bittorrent(fileCount: 0, selectedFileCount: 0, peerCount: 0, shareRatio: 0),
                postDownload: postDownload,
                sourceLink: original
            )
        case .ed2k(let fileName, let size, let hash, let original):
            self.init(
                name: fileName,
                fileExtension: URL(filePath: fileName).pathExtension.nilIfEmpty,
                kind: .ed2k,
                status: .waitingForSources,
                totalBytes: size,
                receivedBytes: 0,
                detail: .ed2k(
                    hash: hash,
                    longTail: LongTailInfo(
                        queueRank: nil,
                        sourceCount: 0,
                        completeSourceCount: 0,
                        lastCompleteSourceSeen: nil,
                        waitingSince: .now,
                        activeTransferDuration: .zero,
                        dailySourceSightings: Array(repeating: 0, count: 14)
                    )
                ),
                postDownload: postDownload,
                sourceLink: original
            )
        case .http(let url, _, let original):
            self.init(
                name: url.lastPathComponent.isEmpty ? (url.host() ?? original) : url.lastPathComponent,
                fileExtension: url.pathExtension.nilIfEmpty,
                kind: .http,
                status: .downloading,
                totalBytes: nil,
                receivedBytes: 0,
                detail: .http(connections: 8),
                postDownload: postDownload,
                sourceLink: original
            )
        case .video(let url, let site, let original):
            self.init(
                name: url.absoluteString,
                fileExtension: "mp4",
                kind: .video,
                status: .downloading,
                totalBytes: nil,
                receivedBytes: 0,
                detail: .video(site: site, quality: "自动", danmakuToASS: site == .bilibili),
                postDownload: postDownload,
                sourceLink: original
            )
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import Foundation

enum Ed2kStatusMapper {
    static func status(code: UInt64, stopped: Bool, rate: Int64) -> TaskStatus {
        switch code {
        case 4, 5, 6: .failed
        case 7: .paused
        case 9: .completed
        case 2, 3, 8, 10: .downloading
        case 0, 1: stopped ? .paused : rate > 0 ? .downloading : .waitingForSources
        default: .failed
        }
    }

    static func snapshot(tag: ECTag, record: Ed2kTaskRecord, rank: Int?, now: Date) throws -> EngineTaskSnapshot {
        guard let code = tag.tag(ECCode.Tag.status)?.number else { throw ECError.malformed(String(localized: "缺少任务状态", bundle: .module)) }
        let rate = Int64(clamping: tag.tag(ECCode.Tag.speed)?.number ?? 0)
        let status = status(code: code, stopped: tag.tag(ECCode.Tag.stopped)?.number == 1, rate: rate)
        let sources = Int(clamping: tag.tag(ECCode.Tag.sources)?.number ?? 0)
        let complete = Int(clamping: tag.tag(ECCode.Tag.completeSources)?.number ?? 0)
        return EngineTaskSnapshot(
            engineTaskID: record.hash, name: record.name, totalBytes: record.size,
            receivedBytes: status == .completed ? record.size : record.received,
            downloadRate: rate, uploadRate: Int64(clamping: tag.tag(ECCode.Tag.uploadSpeed)?.number ?? 0),
            status: status, connections: Int(clamping: tag.tag(ECCode.Tag.transferringSources)?.number ?? 0),
            savePath: record.completedPath ?? safePath(name: record.name, directory: record.directory),
            sourceURL: record.source.flatMap(URL.init(string:)),
            errorMessage: status == .failed ? Ed2kErrorDescriptions.status(code) ?? String(localized: "电驴文件状态异常（aMule 状态码 \(code)）", bundle: .module) : nil,
            detail: .ed2k(hash: record.hash, longTail: record.longTail(
                queueRank: rank, sources: sources, completeSources: complete, now: now
            )), completedAt: record.completedAt
        )
    }

    static func completed(_ record: Ed2kTaskRecord, now: Date) -> EngineTaskSnapshot {
        EngineTaskSnapshot(
            engineTaskID: record.hash, name: record.name, totalBytes: record.size,
            receivedBytes: record.size, downloadRate: 0, uploadRate: 0, status: .completed,
            connections: 0, savePath: record.completedPath,
            sourceURL: record.source.flatMap(URL.init(string:)), errorMessage: nil,
            detail: .ed2k(hash: record.hash, longTail: record.longTail(
                queueRank: nil, sources: 0, completeSources: 0, now: now
            )), completedAt: record.completedAt
        )
    }

    static func safePath(name: String, directory: URL) -> URL? {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else { return nil }
        return directory.appendingPathComponent(name)
    }
}

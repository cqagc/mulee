import Foundation

/// 由 Ed2kEngine actor 独占；每分钟至多一次写盘，添加、删除、完成和退出立即保存。
struct Ed2kHistory: Sendable {
    let url: URL
    var records: [String: Ed2kTaskRecord] = [:]
    private var observations: [String: (time: Date, transferring: Bool)] = [:]
    private var lastWrite: Date?
    private var dirty = false

    init(directory: URL) throws {
        url = directory.appendingPathComponent("mulee-history.json")
        if FileManager.default.fileExists(atPath: url.path) {
            records = try JSONDecoder().decode([String: Ed2kTaskRecord].self, from: Data(contentsOf: url))
        }
    }

    mutating func store(_ record: Ed2kTaskRecord) {
        records[record.hash] = record
        dirty = true
    }

    mutating func remove(_ hash: String) {
        records[hash] = nil
        observations[hash] = nil
        dirty = true
    }

    mutating func observe(_ hash: String, received: Int64, rate: Int64, sources: Int, lastComplete: Date?, now: Date) {
        guard var record = records[hash] else { return }
        if let previous = observations[hash], previous.transferring {
            // 断线、睡眠或停机期间不推算传输时间。
            let interval = now.timeIntervalSince(previous.time)
            if interval > 0, interval <= 30 { record.transferSeconds += interval }
        }
        observations[hash] = (now, rate > 0)
        record.received = received
        if let lastComplete { record.lastCompleteSourceSeen = lastComplete }
        // 一分钟至多采样一次；计的是观察到来源的次数，不宣称是去重后的远端人数。
        if sources > 0, record.lastSighting.map({ now.timeIntervalSince($0) >= 60 }) ?? true {
            record.sightings[Ed2kTaskRecord.day(now), default: 0] += sources
            record.lastSighting = now
        }
        let days = Set((0..<14).map { Ed2kTaskRecord.day(now.addingTimeInterval(Double(-$0) * 86400)) })
        record.sightings = record.sightings.filter { days.contains($0.key) }
        store(record)
    }

    mutating func resetObservations() { observations.removeAll() }

    mutating func flush(now: Date = Date(), force: Bool = false) throws {
        guard dirty, force || lastWrite.map({ now.timeIntervalSince($0) >= 60 }) ?? true else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Ed2kConfiguration.writePrivate(encoder.encode(records), to: url)
        lastWrite = now
        dirty = false
    }
}

import Darwin
import Foundation
import MuleeCore
import Observation

/// 只接收协调器已有的采样通知；历史任务作为基线，不把导入的历史重复计费。
@MainActor
@Observable
final class TransferStatisticsStore {
    struct Traffic: Codable, Equatable {
        var downloaded: Int64 = 0
        var uploaded: Int64 = 0

        mutating func add(downloaded: Int64, uploaded: Int64) {
            self.downloaded = Self.sum(self.downloaded, downloaded)
            self.uploaded = Self.sum(self.uploaded, uploaded)
        }

        private static func sum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
            let (sum, overflow) = lhs.addingReportingOverflow(max(0, rhs))
            return overflow ? .max : sum
        }
    }

    struct Day: Codable, Identifiable, Equatable {
        var date: Date
        var traffic: Traffic
        var id: Date { date }
    }

    struct Sample: Identifiable, Equatable {
        var date: Date
        var download: Int64
        var upload: Int64
        var id: Date { date }
    }

    enum HistoryRange: Int, CaseIterable, Identifiable {
        case tenMinutes = 600
        case oneHour = 3600
        var id: Self { self }
        var title: String {
            switch self {
            case .tenMinutes: String(localized: "最近 10 分钟")
            case .oneHour: String(localized: "最近 1 小时")
            }
        }
    }

    private struct Archive: Codable {
        var total = Traffic()
        var byKind: [String: Traffic] = [:]
        var days: [Day] = []
    }

    private(set) var total = Traffic()
    private(set) var byKind: [String: Traffic] = [:]
    private(set) var days: [Day] = []
    private(set) var recentSamples: [Sample] = []
    private(set) var hourlySamples: [Sample] = []
    private(set) var issue: String?
    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var received: [UUID: Int64] = [:]
    @ObservationIgnored private var lastSample: Date?
    @ObservationIgnored private var lastSave: Date
    @ObservationIgnored private var bucketDate: Date?
    @ObservationIgnored private var bucketDownload = 0.0
    @ObservationIgnored private var bucketUpload = 0.0
    @ObservationIgnored private var bucketCount = 0

    // 不提供真实目录默认值，测试必须显式注入临时文件。
    init(fileURL: URL, now: @escaping () -> Date = Date.init, calendar: Calendar = .current) {
        self.fileURL = fileURL
        self.now = now
        self.calendar = calendar
        self.lastSave = now()
        load()
    }

    func record(tasks: [DownloadTask]) {
        let date = now()
        let active = tasks.filter { $0.deletedAt == nil }
        // 睡眠或轮询停顿期间没有采样，不能用恢复前的瞬时上传速度外推整段流量。
        let elapsed = min(5, max(0, date.timeIntervalSince(lastSample ?? date)))
        let hasBaseline = lastSample != nil
        let day = calendar.startOfDay(for: date)
        var traffic = Traffic()
        for task in active {
            let bytes = max(0, task.receivedBytes)
            let old = received[task.id] ?? (hasBaseline ? 0 : bytes)
            let download = hasBaseline ? max(0, bytes - old) : 0
            let upload = Int64(min(Double(Int64.max / 2), Double(max(0, task.uploadRate)) * elapsed))
            traffic.add(downloaded: download, uploaded: upload)
            var kind = byKind[task.kind.rawValue] ?? Traffic()
            kind.add(downloaded: download, uploaded: upload)
            byKind[task.kind.rawValue] = kind
        }
        // 保留回收站记录的基线，恢复记录不会被误算成一次全新的下载。
        received = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, max(0, $0.receivedBytes)) })
        lastSample = date
        total.add(downloaded: traffic.downloaded, uploaded: traffic.uploaded)
        if let index = days.firstIndex(where: { $0.date == day }) {
            days[index].traffic.add(downloaded: traffic.downloaded, uploaded: traffic.uploaded)
        } else {
            days.append(Day(date: day, traffic: traffic))
        }
        pruneDays(at: date)
        appendSample(Sample(
            date: date, download: rate(active.map(\.downloadRate)), upload: rate(active.map(\.uploadRate))
        ))
        if date.timeIntervalSince(lastSave) >= 60 { save() }
    }

    func history(_ range: HistoryRange) -> [Sample] {
        let window = historyWindow(range)
        return (range == .tenMinutes ? recentSamples : hourlySamples).filter { window.contains($0.date) }
    }

    func historyWindow(_ range: HistoryRange) -> ClosedRange<Date> {
        let end = now()
        return end.addingTimeInterval(-Double(range.rawValue))...end
    }

    func recentDays() -> [Day] {
        let today = calendar.startOfDay(for: now())
        return (-29...0).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return days.first { $0.date == day } ?? Day(date: day, traffic: Traffic())
        }
    }

    func reset() {
        total = Traffic()
        byKind = [:]
        days = []
        recentSamples = []
        hourlySamples = []
        bucketDate = nil
        bucketCount = 0
        bucketDownload = 0
        bucketUpload = 0
        // 保留当前任务字节基线，下一次采样只计算重置之后的增量。
        save()
    }

    func save() {
        let manager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        let temporary = directory.appending(path: ".statistics-\(UUID().uuidString).tmp")
        do {
            pruneDays(at: now())
            let data = try JSONEncoder().encode(Archive(total: total, byKind: byKind, days: days))
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // 临时文件从创建起就是 0600；同目录 rename 保证替换原子性。
            guard manager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            defer { try? manager.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            guard rename(temporary.path, fileURL.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            lastSave = now()
            issue = nil
        } catch {
            issue = String(localized: "统计无法保存，请检查应用支持目录的可用空间和写入权限。")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            let traffic = [archive.total] + Array(archive.byKind.values) + archive.days.map(\.traffic)
            guard traffic.allSatisfy({ $0.downloaded >= 0 && $0.uploaded >= 0 }),
                  archive.days.allSatisfy({ $0.date.timeIntervalSince1970.isFinite }) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            total = archive.total
            byKind = archive.byKind.filter { TaskKind(rawValue: $0.key) != nil }
            days = archive.days
            pruneDays(at: now())
        } catch {
            issue = String(localized: "统计文件已损坏或无法读取，已从零开始统计；下载任务不受影响。")
        }
    }

    private func pruneDays(at date: Date) {
        let today = calendar.startOfDay(for: date)
        guard let first = calendar.date(byAdding: .day, value: -29, to: today) else { return }
        days = Array(days.filter { $0.date >= first && $0.date <= today }.sorted { $0.date < $1.date }.suffix(30))
    }

    private func rate(_ values: [Int64]) -> Int64 {
        values.reduce(Int64(0)) { total, value in
            let (result, overflow) = total.addingReportingOverflow(max(0, value))
            return overflow ? .max : result
        }
    }

    private func appendSample(_ sample: Sample) {
        recentSamples.removeAll { $0.date < sample.date.addingTimeInterval(-600) || $0.date >= sample.date }
        recentSamples.append(sample)
        if recentSamples.count > 601 { recentSamples.removeFirst(recentSamples.count - 601) }
        let bucket = Date(timeIntervalSince1970: floor(sample.date.timeIntervalSince1970 / 10) * 10)
        if bucketDate != bucket {
            bucketDate = bucket
            bucketDownload = 0
            bucketUpload = 0
            bucketCount = 0
        } else if !hourlySamples.isEmpty {
            hourlySamples.removeLast()
        }
        bucketCount += 1
        bucketDownload += Double(sample.download)
        bucketUpload += Double(sample.upload)
        hourlySamples.removeAll { $0.date < bucket.addingTimeInterval(-3600) || $0.date >= bucket }
        hourlySamples.append(Sample(
            date: bucket, download: Int64(min(Double(Int64.max / 2), bucketDownload / Double(bucketCount))),
            upload: Int64(min(Double(Int64.max / 2), bucketUpload / Double(bucketCount)))
        ))
        if hourlySamples.count > 361 { hourlySamples.removeFirst(hourlySamples.count - 361) }
    }
}

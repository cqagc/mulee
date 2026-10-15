import Foundation

/// XML 不保证时间顺序。分块排序、至多 32 路归并，使内存和打开的文件数有界。
struct DanmakuCommentSorter: Sendable {
    let directory: URL
    private var batch: [DanmakuComment] = []
    private var runs: [URL] = []
    private var batchBytes = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(directory: URL) {
        self.directory = directory
    }

    mutating func append(_ comment: DanmakuComment) throws {
        batch.append(comment)
        batchBytes += comment.text.utf8.count
        if batch.count >= 4096 || batchBytes >= 4_194_304 { try flush() }
    }

    mutating func forEach(_ body: (DanmakuComment) throws -> Void) throws {
        if runs.isEmpty {
            for comment in batch.sorted(by: Self.ordered) { try body(comment) }
            return
        }
        try flush()
        while runs.count > 32 {
            var merged: [URL] = []
            for start in stride(from: 0, to: runs.count, by: 32) {
                let group = Array(runs[start..<min(start + 32, runs.count)])
                let url = directory.appendingPathComponent(UUID().uuidString)
                let output = try create(url)
                defer { try? output.close() }
                try merge(group) { try write($0, to: output) }
                try output.close()
                for old in group { try FileManager.default.removeItem(at: old) }
                merged.append(url)
            }
            runs = merged
        }
        try merge(runs, body: body)
    }

    private mutating func flush() throws {
        guard !batch.isEmpty else { return }
        let url = directory.appendingPathComponent(UUID().uuidString)
        let output = try create(url)
        defer { try? output.close() }
        batch.sort(by: Self.ordered)
        for comment in batch { try write(comment, to: output) }
        try output.close()
        runs.append(url)
        batch.removeAll(keepingCapacity: true)
        batchBytes = 0
    }

    private func merge(_ urls: [URL], body: (DanmakuComment) throws -> Void) throws {
        var inputs: [FileHandle] = []
        defer { for input in inputs { try? input.close() } }
        for url in urls { inputs.append(try FileHandle(forReadingFrom: url)) }
        var heads = try inputs.map { try read($0) }
        while let index = heads.indices.filter({ heads[$0] != nil }).min(by: { lhs, rhs in
            guard let left = heads[lhs], let right = heads[rhs] else { return false }
            return Self.ordered(left, right)
        }), let comment = heads[index] {
            try Task.checkCancellation()
            try body(comment)
            heads[index] = try read(inputs[index])
        }
    }

    private static func ordered(_ lhs: DanmakuComment, _ rhs: DanmakuComment) -> Bool {
        lhs.time == rhs.time ? lhs.ordinal < rhs.ordinal : lhs.time < rhs.time
    }

    private func create(_ url: URL) throws -> FileHandle {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try FileHandle(forWritingTo: url)
    }

    private func write(_ comment: DanmakuComment, to output: FileHandle) throws {
        let data = try encoder.encode(comment)
        let size = UInt32(data.count)
        let prefix = Data((0..<4).map { UInt8(truncatingIfNeeded: size >> ($0 * 8)) })
        try output.write(contentsOf: prefix)
        try output.write(contentsOf: data)
    }

    private func read(_ input: FileHandle) throws -> DanmakuComment? {
        guard let prefix = try input.read(upToCount: 4), !prefix.isEmpty else { return nil }
        guard prefix.count == 4 else { throw CocoaError(.fileReadCorruptFile) }
        let size = prefix.enumerated().reduce(0) { $0 | Int($1.element) << ($1.offset * 8) }
        guard size <= 524_288, let data = try input.read(upToCount: size), data.count == size else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return try decoder.decode(DanmakuComment.self, from: data)
    }
}

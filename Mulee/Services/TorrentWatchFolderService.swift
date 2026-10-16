import Darwin
import Foundation
import MuleeCore
import Observation

/// 目录事件唤醒扫描，定时采样只用于等待写入稳定；失败的文件留在原位。
@Observable
final class TorrentWatchFolderService {
    typealias Handler = (URL, String, Bool) async throws -> Bool

    private struct Stamp: Equatable {
        let size: Int
        let modified: Date?
        let identifier: UInt64?
    }

    private struct Candidate {
        let stamp: Stamp
        let since: Date
    }

    private(set) var lastError: String?
    private var candidates: [URL: Candidate] = [:]
    private var attempted: [URL: Stamp] = [:]
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var configuredFolders = Set<String>()
    private var worker: Task<Void, Never>?
    private var processing: Task<Void, Never>?
    private var generation = 0
    private var needsScan = true
    private let manager = FileManager.default

    isolated deinit {
        worker?.cancel()
        processing?.cancel()
        for source in sources.values { source.cancel() }
    }

    func start(settings: SettingsModel, handler: @escaping Handler) {
        stop()
        let token = generation
        worker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == token else { return }
                self.configure(folders: settings.watchFolders)
                if self.processing == nil, self.needsScan || !self.candidates.isEmpty {
                    let folders = settings.watchFolders.map { URL(filePath: $0) }
                    let autoStart = settings.watchAutoStart
                    self.processing = Task { [weak self] in
                        guard let self else { return }
                        await self.scan(folders: folders, autoStart: autoStart, handler: handler)
                        if self.generation == token { self.processing = nil }
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        processing?.cancel()
        processing = nil
        for source in sources.values { source.cancel() }
        sources.removeAll()
        configuredFolders.removeAll()
        candidates.removeAll()
        attempted.removeAll()
        needsScan = true
    }

    func retry() {
        attempted.removeAll()
        lastError = nil
        needsScan = true
    }

    private func configure(folders: [String]) {
        let requested = Set(folders.map { URL(filePath: $0).resolvingSymlinksInPath().path })
        if requested != configuredFolders {
            processing?.cancel()
            configuredFolders = requested
            candidates = candidates.filter { requested.contains($0.key.deletingLastPathComponent().resolvingSymlinksInPath().path) }
            attempted = attempted.filter { requested.contains($0.key.deletingLastPathComponent().resolvingSymlinksInPath().path) }
            needsScan = true
        }
        for path in Array(sources.keys) where !requested.contains(path) {
            sources.removeValue(forKey: path)?.cancel()
        }
        for path in requested where sources[path] == nil {
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else {
                lastError = String(localized: "无法监视文件夹，请确认目录存在并允许访问。")
                continue
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
            )
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.needsScan = true }
            }
            source.setCancelHandler { close(descriptor) }
            sources[path] = source
            source.resume()
            needsScan = true
        }
    }

    /// now 可注入，测试用真文件验证一秒稳定窗口，不依赖计时器调度。
    func scan(folders: [URL], autoStart: Bool, now: Date = .now, handler: Handler) async {
        let token = generation
        needsScan = false
        var existing = Set<URL>()
        for folder in folders {
            guard !Task.isCancelled, token == generation else { return }
            do {
                let files = try manager.contentsOfDirectory(
                    at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]
                ).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for file in files where ["torrent", "magnet"].contains(file.pathExtension.lowercased()) {
                    guard !Task.isCancelled, token == generation else { return }
                    let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                    existing.insert(file)
                    let stamp = try stamp(for: file)
                    guard attempted[file] != stamp else { continue }
                    guard let candidate = candidates[file], candidate.stamp == stamp else {
                        candidates[file] = Candidate(stamp: stamp, since: now)
                        continue
                    }
                    guard now.timeIntervalSince(candidate.since) >= 1 else { continue }
                    attempted[file] = stamp
                    do {
                        let text = try Self.inputText(for: file)
                        let accepted = try await handler(file, text, autoStart)
                        guard !Task.isCancelled, token == generation else { return }
                        // 确认期间若文件被替换，不归档后来写入的内容。
                        guard try self.stamp(for: file) == stamp else {
                            candidates.removeValue(forKey: file)
                            continue
                        }
                        if accepted { _ = try Self.archive(file) }
                    } catch {
                        guard !Task.isCancelled, token == generation else { return }
                        lastError = String(localized: "未处理 \(file.lastPathComponent)：\(EngineStatusPresentation.errorMessage(error))")
                    }
                    candidates.removeValue(forKey: file)
                }
            } catch {
                lastError = String(localized: "无法读取监视文件夹，请确认目录存在并允许访问。")
            }
        }
        candidates = candidates.filter { existing.contains($0.key) }
        attempted = attempted.filter { existing.contains($0.key) }
    }

    private func stamp(for file: URL) throws -> Stamp {
        let attributes = try manager.attributesOfItem(atPath: file.path)
        return Stamp(
            size: (attributes[.size] as? NSNumber)?.intValue ?? 0,
            modified: attributes[.modificationDate] as? Date,
            identifier: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    static func inputText(for file: URL) throws -> String {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        if file.pathExtension.lowercased() == "torrent" {
            guard size > 0, size <= 16 * 1_024 * 1_024 else {
                throw CocoaError(.fileReadTooLarge)
            }
            _ = try TorrentFileInfo.parse(data: Data(contentsOf: file))
            return file.absoluteString
        }
        guard size <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let links = SmartPasteParser.parse(text).flatMap(\.links)
        guard text.lowercased().hasPrefix("magnet:?"), !text.contains(where: \.isWhitespace),
              links.count == 1, case .magnet = links[0] else {
            throw NSError(domain: "TorrentWatchFolder", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "文件需要只包含一个完整磁力链接，请修改后重试。")
            ])
        }
        return text
    }

    static func archive(_ file: URL) throws -> URL {
        let manager = FileManager.default
        let directory = file.deletingLastPathComponent().appending(path: ".mulee-added", directoryHint: .isDirectory)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = file.deletingPathExtension().lastPathComponent
        var number = 0
        while true {
            let name = number == 0 ? file.lastPathComponent : "\(stem) (\(number)).\(file.pathExtension)"
            let target = directory.appendingPathComponent(name)
            do {
                try manager.moveItem(at: file, to: target)
                return target
            } catch CocoaError.fileWriteFileExists {
                number += 1
            }
        }
    }
}

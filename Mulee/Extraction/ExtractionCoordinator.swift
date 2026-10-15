import Foundation
import MuleeCore

/// 下载完成后的串行解压队列。所有任务展示状态只在主线程更新。
@MainActor
final class ExtractionCoordinator {
    private let model: AppModel
    private let settings: SettingsModel
    private let extractor: any ArchiveExtracting
    private var worker: Task<Void, Never>?
    private var activeJob: ExtractionJob?
    private var candidates: [DownloadTask.ID] = []
    private var seenCompletions: Set<DownloadTask.ID> = []
    private var waitingSignatures: [DownloadTask.ID: [String]] = [:]
    private var isUpdating = false
    private var isStopped = true

    init(model: AppModel, settings: SettingsModel, extractor: any ArchiveExtracting) {
        self.model = model
        self.settings = settings
        self.extractor = extractor
        model.extractionCoordinator = self
    }

    func start() {
        guard isStopped, worker == nil else { return }
        isStopped = false
        isUpdating = true
        // 上次退出或中断的解压不自动重试，避免重复生成产物。
        for index in model.tasks.indices where model.tasks[index].postDownload.extractionState == .extracting
            || model.tasks[index].status == .extracting {
            model.tasks[index].status = .completed
            model.tasks[index].postDownload.extractionState = .cancelled
            model.tasks[index].postDownload.extractionFailure = "上次解压已中断，原压缩包已保留"
        }
        isUpdating = false
        tasksDidChange()
    }

    func cancel() {
        isStopped = true
        worker?.cancel()
    }

    func stop() async {
        cancel()
        await worker?.value
        model.flushTaskHistory()
    }

    func tasksDidChange() {
        guard !isStopped, !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        // 引擎仍会报告下载完成；解压期间以 App 的后处理状态为准。
        if let activeJob {
            for index in model.tasks.indices where activeJob.taskIDs.contains(model.tasks[index].id) {
                if model.tasks[index].status != .extracting {
                    model.tasks[index].status = .extracting
                }
            }
        }
        for task in model.tasks where task.status == .completed {
            guard seenCompletions.insert(task.id).inserted else { continue }
            guard settings.autoExtract, task.postDownload.autoExtract,
                  !Self.isFinished(task.postDownload), let path = task.savePath,
                  ArchiveVolumeDetector.detect(filename: path.lastPathComponent, directoryFilenames: []).isArchive else { continue }
            candidates.append(task.id)
            update([task.id]) { $0.postDownload.extractionState = .queued }
        }
        if worker == nil, !candidates.isEmpty {
            worker = Task { [weak self] in
                await self?.drain()
            }
        }
    }

    private func drain() async {
        while !Task.isCancelled, !isStopped, let job = nextJob() {
            activeJob = job
            update(job.taskIDs) { task in
                task.status = .extracting
                task.postDownload.extractionState = .extracting
                task.postDownload.extractProgress = 0
                task.postDownload.extractionFailure = nil
                task.postDownload.matchedRuleName = UnzipRuleMatcher.match(
                    rules: job.rules, filename: job.archive.lastPathComponent, sourceURL: job.sourceURL
                ).matchedRule?.pattern
            }
            model.flushTaskHistory()
            let extractionRules = await rulesIncludingPagePassword(for: job)
            var outcome = await extractor.extract(
                archive: job.archive, destination: job.destination,
                rules: extractionRules, sourceURL: job.sourceURL, options: job.options
            ) { [weak self] value in
                Task { @MainActor [weak self] in
                    self?.reportProgress(value, jobID: job.id)
                }
            }
            if extractionRules != job.rules {
                if outcome.failure == .wrongPasswords, !Task.isCancelled {
                    outcome = await extractor.extract(
                        archive: job.archive, destination: job.destination,
                        rules: job.rules, sourceURL: job.sourceURL, options: job.options
                    ) { [weak self] value in
                        Task { @MainActor [weak self] in self?.reportProgress(value, jobID: job.id) }
                    }
                }
                do {
                    try await model.extractionPasswords.setPassword(nil, for: "page-password-" + job.id.uuidString)
                } catch {
                    model.unzipRuleIssue = "无法移除临时解压密码：\(error.localizedDescription)"
                }
            }
            finish(outcome, job: job)
            activeJob = nil
            model.flushTaskHistory()
        }
        worker = nil
    }

    private func nextJob() -> ExtractionJob? {
        guard settings.autoExtract else {
            update(Set(candidates)) { task in
                task.postDownload.extractionState = .cancelled
                task.postDownload.extractionFailure = "自动解压已关闭"
            }
            candidates.removeAll()
            return nil
        }
        for id in candidates {
            guard let task = model.tasks.first(where: { $0.id == id }), task.status == .completed,
                  task.postDownload.autoExtract, !Self.isFinished(task.postDownload), let archive = task.savePath else {
                candidates.removeAll { $0 == id }
                continue
            }
            let directory = archive.deletingLastPathComponent().standardizedFileURL
            let peers = model.tasks.filter {
                let parent = $0.savePath?.deletingLastPathComponent().standardizedFileURL
                    ?? URL(filePath: settings.saveDirectory).standardizedFileURL
                return parent == directory
            }
            let knownNames = peers.map { $0.savePath?.lastPathComponent ?? $0.name }
            let diskNames: [String]
            do {
                diskNames = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            } catch {
                update([id]) { task in
                    task.postDownload.extractionState = .failed
                    task.postDownload.extractionFailure = "暂时无法读取压缩包所在文件夹"
                }
                candidates.removeAll { $0 == id }
                continue
            }
            let knownSet = ArchiveVolumeDetector.detect(
                filename: archive.lastPathComponent, directoryFilenames: Array(Set(knownNames + diskNames))
            )
            let names = Set((knownSet.volumes + [archive.lastPathComponent]).map { $0.lowercased() })
            let group = peers.filter { names.contains(($0.savePath?.lastPathComponent ?? $0.name).lowercased()) }
            let ids = Set(group.map(\.id))
            // 同一组的任意分卷已经处理过时，不重复解压整个压缩包。
            if let finished = group.first(where: { Self.isFinished($0.postDownload) }) {
                update(ids) { $0.postDownload = finished.postDownload }
                candidates.removeAll { ids.contains($0) }
                continue
            }
            let volumeNames = knownSet.isMultipart ? knownSet.volumes : nil
            let detected = ArchiveVolumeDetector.detect(
                filename: archive.lastPathComponent, directoryFilenames: diskNames,
                expectedVolumeNames: volumeNames
            )
            let signature = detected.volumes.sorted() + group.map { "\($0.id):\($0.status)" }.sorted()
            guard group.allSatisfy({ $0.status == .completed }), !detected.isMultipart || detected.missingVolumes.isEmpty else {
                markWaiting(ids)
                continue
            }
            guard waitingSignatures[id] != signature else { continue }
            let main = directory.appendingPathComponent(detected.mainVolume ?? archive.lastPathComponent)
            let source = group.first { $0.savePath?.lastPathComponent == main.lastPathComponent } ?? task
            candidates.removeAll { ids.contains($0) }
            seenCompletions.formUnion(ids)
            return ExtractionJob(
                taskIDs: ids, archive: main, destination: directory,
                sourceURL: source.sourcePageURL ?? URL(string: source.sourceLink), rules: model.unzipRules,
                options: options(volumeNames: volumeNames), signature: signature
            )
        }
        return nil
    }

    private func rulesIncludingPagePassword(for job: ExtractionJob) async -> [UnzipRule] {
        guard let password = job.taskIDs.compactMap({ model.pagePasswords[$0] }).first else { return job.rules }
        let key = "page-password-" + job.id.uuidString
        do {
            try await model.extractionPasswords.setPassword(password, for: key)
            return [UnzipRule(
                matchKind: .filenamePrefix, pattern: "*", keychainItemID: key,
                maskedLength: password.count, hitCount: 0
            )]
        } catch {
            model.unzipRuleIssue = "无法临时保存页面解压密码：\(error.localizedDescription)"
            return job.rules
        }
    }

    private func options(volumeNames: [String]?) -> ExtractionOptions {
        let encoding: ArchiveFilenameEncoding = switch settings.filenameEncoding {
        case .auto: .automatic
        case .gbk: .gbk
        case .big5: .big5
        case .shiftJIS: .shiftJIS
        }
        let action: ExtractionPostAction = switch settings.originalAction {
        case .keep: .keep
        case .trash: .trash
        case .delete: .delete
        }
        return ExtractionOptions(
            encoding: encoding, postAction: action, recursivelyExtract: settings.extractNested,
            expectedVolumeNames: volumeNames
        )
    }

    private func reportProgress(_ value: Double, jobID: UUID) {
        guard value.isFinite, let job = activeJob, job.id == jobID else { return }
        update(job.taskIDs) { $0.postDownload.extractProgress = min(1, max(0, value)) }
    }

    private func markWaiting(_ ids: Set<DownloadTask.ID>) {
        update(ids) { task in
            guard task.status == .completed, task.postDownload.extractionState != .waitingForVolumes else { return }
            task.postDownload.extractionState = .waitingForVolumes
            task.postDownload.extractProgress = nil
        }
    }

    private func finish(_ outcome: ExtractionOutcome, job: ExtractionJob) {
        update(job.taskIDs) { task in
            task.status = .completed
            task.postDownload.filenameEncoding = outcome.encoding == .automatic ? nil : outcome.encoding.rawValue
            task.postDownload.extractionWarnings = outcome.warnings.isEmpty ? nil : outcome.warnings
            switch outcome.status {
            case .succeeded:
                task.postDownload.extractionState = .succeeded
                task.postDownload.extractProgress = 1
                task.postDownload.extractedItems = outcome.items
                task.postDownload.extractionFailure = nil
            case .waitingForVolumes:
                task.postDownload.extractionState = .waitingForVolumes
                task.postDownload.extractProgress = nil
            case .failed:
                task.postDownload.extractionState = outcome.failure == .cancelled ? .cancelled : .failed
                task.postDownload.extractProgress = nil
                task.postDownload.extractionFailure = outcome.failure?.localizedDescription ?? "暂时没能解压，原压缩包已保留"
            }
        }
        if outcome.status == .waitingForVolumes {
            for id in job.taskIDs {
                waitingSignatures[id] = job.signature
                if !candidates.contains(id) { candidates.append(id) }
            }
        }
        if let rule = outcome.matchedRule, let index = model.unzipRules.firstIndex(where: { $0.id == rule.id }) {
            model.unzipRules[index].hitCount += 1
        }
    }

    private func update(_ ids: Set<DownloadTask.ID>, change: (inout DownloadTask) -> Void) {
        let previous = isUpdating
        isUpdating = true
        defer { isUpdating = previous }
        var tasks = model.tasks
        for index in tasks.indices where ids.contains(tasks[index].id) {
            change(&tasks[index])
        }
        if tasks != model.tasks { model.tasks = tasks }
    }

    private static func isFinished(_ info: PostDownloadInfo) -> Bool {
        [.succeeded, .failed, .cancelled].contains(info.extractionState) || info.extractProgress == 1
    }
}

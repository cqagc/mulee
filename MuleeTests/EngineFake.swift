import Foundation
import MuleeCore

actor FakeEngine: DownloadEngine {
    nonisolated let kind: TaskKind
    private(set) var isRunning = false
    private(set) var stopCount = 0
    private(set) var addedLinks: [ParsedLink] = []
    private(set) var queuedLinks: [ParsedLink] = []
    private(set) var directories: [URL?] = []
    private(set) var pausedIDs: [String] = []
    private(set) var resumedIDs: [String] = []
    private(set) var removedIDs: [String] = []
    private(set) var deletesFiles: [Bool] = []
    private(set) var appliedOptions: [EngineOptions] = []
    private(set) var taskLimits: [(id: String, download: Int64, upload: Int64)] = []
    private var currentSnapshots: [EngineTaskSnapshot] = []
    private var startError: EngineError?
    private var operationError: EngineError?
    private var snapshotError: EngineError?
    private var applyError: EngineError?
    private var holdsSnapshot = false
    private var snapshotWaiter: CheckedContinuation<Void, Never>?
    private var snapshotStartedWaiter: CheckedContinuation<Void, Never>?

    init(kind: TaskKind = .http, startError: EngineError? = nil) {
        self.kind = kind
        self.startError = startError
    }

    func start(options: EngineOptions) async throws {
        if let startError { throw startError }
        isRunning = true
    }

    func stop() async {
        isRunning = false
        stopCount += 1
    }

    func apply(options: EngineOptions) async throws {
        if let applyError { throw applyError }
        appliedOptions.append(options)
    }

    func add(link: ParsedLink, directory: URL?) async throws -> String {
        if let operationError { throw operationError }
        addedLinks.append(link)
        directories.append(directory)
        return "task-\(addedLinks.count)"
    }

    func addQueued(link: ParsedLink, directory: URL?) async throws -> String {
        queuedLinks.append(link)
        let id = try await add(link: link, directory: directory)
        try await pause(id)
        return id
    }

    func pause(_ engineTaskID: String) async throws {
        if let operationError { throw operationError }
        pausedIDs.append(engineTaskID)
    }

    func setTaskLimits(id: String, download: Int64, upload: Int64) async throws {
        if let operationError { throw operationError }
        taskLimits.append((id, download, upload))
    }

    func resume(_ engineTaskID: String) async throws {
        if let operationError { throw operationError }
        resumedIDs.append(engineTaskID)
    }

    func remove(_ engineTaskID: String, deleteFiles: Bool) async throws {
        if let operationError { throw operationError }
        removedIDs.append(engineTaskID)
        deletesFiles.append(deleteFiles)
    }

    func snapshots() async throws -> [EngineTaskSnapshot] {
        if let snapshotError { throw snapshotError }
        let captured = currentSnapshots
        if holdsSnapshot {
            await withCheckedContinuation { continuation in
                snapshotWaiter = continuation
                snapshotStartedWaiter?.resume()
                snapshotStartedWaiter = nil
            }
            holdsSnapshot = false
        }
        return captured
    }

    func setSnapshots(_ snapshots: [EngineTaskSnapshot]) {
        currentSnapshots = snapshots
    }

    func failOperations(with error: EngineError?) {
        operationError = error
    }

    func failSnapshots(with error: EngineError?) {
        snapshotError = error
    }

    func failApply(with error: EngineError?) {
        applyError = error
    }

    func holdNextSnapshot() {
        holdsSnapshot = true
    }

    func waitForHeldSnapshot() async {
        guard snapshotWaiter == nil else { return }
        await withCheckedContinuation { snapshotStartedWaiter = $0 }
    }

    func releaseSnapshot() {
        snapshotWaiter?.resume()
        snapshotWaiter = nil
    }
}

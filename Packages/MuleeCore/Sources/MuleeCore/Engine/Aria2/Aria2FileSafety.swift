import Darwin
import Foundation

struct Aria2FileSafety: Sendable {
    static func isInside(_ file: URL, directory: URL) -> Bool {
        let root = resolved(directory).pathComponents
        let path = resolved(file).pathComponents
        return path.count > root.count && path.starts(with: root)
    }

    private static func resolved(_ url: URL) -> URL {
        // Resolve existing ancestors even when the final file/control file is absent.
        url.standardizedFileURL.pathComponents.dropFirst().reduce(URL(fileURLWithPath: "/")) {
            $0.appendingPathComponent($1).resolvingSymlinksInPath()
        }
    }

    static func trashFiles(for status: Aria2RPCModels.Status) throws {
        guard let dir = status.dir, dir.hasPrefix("/") else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        for file in status.files ?? [] where file.path.hasPrefix("/") {
            let url = URL(fileURLWithPath: file.path)
            for candidate in [url, URL(fileURLWithPath: file.path + ".aria2")] {
                guard isInside(candidate, directory: directory),
                      FileManager.default.fileExists(atPath: candidate.path) else { continue }
                try FileManager.default.trashItem(at: candidate, resultingItemURL: nil)
            }
        }
    }
}

/// 新任务的独立工作目录。旧任务没有该记录，始终沿用原路径。
public struct IncompleteHTTPTransfer: Codable, Sendable, Equatable {
    public let directory: URL
    public let destination: URL
    public let duplicateAction: DownloadRequestContext.DuplicateAction
    public private(set) var workingFile: URL?
    public private(set) var downloadedBytes: Int64?
    public private(set) var completedFile: URL?
    private var pendingFile: URL?

    public init(taskID: UUID, destination: URL, duplicateAction: DownloadRequestContext.DuplicateAction = .rename) {
        self.destination = destination
        self.duplicateAction = duplicateAction
        directory = destination.appendingPathComponent(".mulee-incomplete", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true)
    }

    public func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (directory.deletingLastPathComponent() as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    public mutating func recordWorkingFile(_ file: URL) {
        guard Aria2FileSafety.isInside(file, directory: directory) else { return }
        workingFile = file
    }

    public mutating func recordCompletion(file: URL, bytes: Int64) {
        guard Aria2FileSafety.isInside(file, directory: directory) else { return }
        workingFile = file
        downloadedBytes = bytes
    }

    public mutating func restart() {
        downloadedBytes = nil
        completedFile = nil
        pendingFile = nil
    }

    public var recoveryFile: URL? {
        if let completedFile { return completedFile }
        if let workingFile, FileManager.default.fileExists(atPath: workingFile.path) { return workingFile }
        return pendingFile ?? workingFile
    }

    /// 先持久化目标名，再 rename，崩溃后可辨认已经完成的移动。
    public mutating func planMove(from file: URL) throws {
        guard completedFile == nil else { return }
        if let pendingFile {
            if duplicateAction == .rename, FileManager.default.fileExists(atPath: file.path),
               FileManager.default.fileExists(atPath: pendingFile.path) {
                self.pendingFile = nil
            } else {
                return
            }
        }
        guard Aria2FileSafety.isInside(file, directory: directory),
              file.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
            throw EngineError.invalidResponse(String(localized: "未完成文件路径不在任务目录中", bundle: .module))
        }
        var target = destination.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            switch duplicateAction {
            case .ask:
                throw EngineError.invalidResponse(String(localized: "目标已有同名文件，请选择重命名或覆盖后重试。", bundle: .module))
            case .overwrite:
                break
            case .rename:
                let stem = target.deletingPathExtension().lastPathComponent
                let ext = target.pathExtension
                var number = 1
                repeat {
                    let name = "\(stem) (\(number))" + (ext.isEmpty ? "" : ".\(ext)")
                    target = destination.appendingPathComponent(name)
                    number += 1
                } while FileManager.default.fileExists(atPath: target.path)
            }
        }
        pendingFile = target
    }

    public mutating func finishMove(from file: URL) throws -> URL {
        if let completedFile { return completedFile }
        guard let target = pendingFile else { throw EngineError.invalidResponse(String(localized: "缺少成品移动记录", bundle: .module)) }
        let manager = FileManager.default
        guard Aria2FileSafety.isInside(file, directory: directory) else {
            throw EngineError.invalidResponse(String(localized: "未完成文件路径不在任务目录中", bundle: .module))
        }
        if manager.fileExists(atPath: file.path) {
            // 两个目录在同一保存卷；rename 原子替换，不做跨卷复制。
            let result = file.withUnsafeFileSystemRepresentation { source in
                target.withUnsafeFileSystemRepresentation { destination in
                    duplicateAction == .overwrite
                        ? Darwin.rename(source!, destination!)
                        : Darwin.renamex_np(source!, destination!, UInt32(RENAME_EXCL))
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else if !manager.fileExists(atPath: target.path) {
            throw CocoaError(.fileNoSuchFile)
        }
        completedFile = target
        return target
    }

    public func cleanup() throws {
        // rmdir 只删除空目录；其他任务或未移动的文件始终保留。
        let parent = directory.deletingLastPathComponent()
        _ = rmdir(directory.path)
        _ = rmdir(parent.path)
    }

    /// 解压和播放都不能把工作目录中的文件当成成品。
    public static func isStagingFile(_ file: URL) -> Bool {
        file.pathComponents.contains(".mulee-incomplete") || file.pathExtension.lowercased() == "mulee"
    }
}

import Foundation

public actor ArchiveExtractor {
    private let binary: URL?
    private let passwords: any PasswordProviding

    public init(binary: URL? = nil, passwords: any PasswordProviding = InMemoryPasswordProvider()) {
        self.binary = binary ?? SevenZipProcess.homebrewBinary
        self.passwords = passwords
    }

    /// expectedVolumeNames 应由 App 传入同一下载批次的完整分卷文件名。
    public func extract(
        archive: URL,
        destination: URL,
        rules: [UnzipRule] = [],
        sourceURL: URL? = nil,
        options: ExtractionOptions = ExtractionOptions(),
        progress: (@Sendable (Double) -> Void)? = nil
    ) async -> ExtractionResult {
        await extract(archive: archive, destination: destination, rules: rules, sourceURL: sourceURL,
                      options: options, depth: 1, progress: progress)
    }

    private func extract(
        archive: URL,
        destination: URL,
        rules: [UnzipRule],
        sourceURL: URL?,
        options: ExtractionOptions,
        depth: Int,
        progress: (@Sendable (Double) -> Void)?
    ) async -> ExtractionResult {
        let match = UnzipRuleMatcher.match(rules: rules, filename: archive.lastPathComponent, sourceURL: sourceURL)
        var encoding = options.encoding
        var originals: [URL] = []
        var warnings = match.errors
        var temporary: URL?
        var usedSource: UnzipPasswordSource?
        do {
            guard let binary else { throw ExtractionFailure.executableMissing }
            let directory = archive.deletingLastPathComponent()
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            let set = ArchiveVolumeDetector.detect(filename: archive.lastPathComponent, directoryFilenames: names,
                                                   expectedVolumeNames: options.expectedVolumeNames,
                                                   expectedVolumeCount: options.expectedVolumeCount)
            originals = set.volumes.map { directory.appendingPathComponent($0) }
            guard set.missingVolumes.isEmpty else { throw ExtractionFailure.missingVolumes(set.missingVolumes) }
            guard set.isArchive, let mainName = set.mainVolume else { throw ExtractionFailure.damagedArchive }
            let main = directory.appendingPathComponent(mainName)
            // 普通压缩包不访问钥匙串；只有工具明确要求密码时才取候选密码。
            let initial = try await SevenZipProcess.run(
                binary: binary, arguments: ["t", "-sccUTF-8", "--", main.path], timeout: options.timeout
            )
            var successfulPassword: String?
            var verified = initial.status == 0
            if !verified {
                let failure = Self.classify(initial.text, multipart: set.isMultipart)
                guard failure == .wrongPasswords else { throw failure }
                var candidates: [String] = []
                for source in match.sources {
                    switch source {
                    case .keychainItem(let id):
                        if let password = try await passwords.password(for: id) { candidates.append(password) }
                    case .passwordBook:
                        candidates += try await passwords.passwordBook()
                    }
                }
                for candidate in candidates {
                    let test = try await SevenZipProcess.run(
                        binary: binary, arguments: ["t", "-sccUTF-8", "--", main.path], password: candidate, timeout: options.timeout
                    )
                    if test.status == 0 {
                        verified = true
                        successfulPassword = candidate
                        usedSource = match.sources.first
                        break
                    }
                    let failure = Self.classify(test.text, multipart: set.isMultipart)
                    if failure != .wrongPasswords { throw failure }
                }
            }
            guard verified else { throw ExtractionFailure.wrongPasswords }
            if encoding == .automatic {
                encoding = try await FilenameEncodingDetector.detect(archive: main, binary: binary, password: successfulPassword)
            }
            let codePage = encoding.codePage.map { ["-mcp=\($0)"] } ?? []
            let listing = try await SevenZipProcess.run(
                binary: binary, arguments: ["l", "-slt", "-ba", "-sccUTF-8"] + codePage + ["--", main.path],
                password: successfulPassword, timeout: options.timeout
            )
            guard listing.status == 0 else { throw Self.classify(listing.text, multipart: set.isMultipart) }
            try ArchivePathSafety.validate(listing: listing.text)
            if main.pathExtension.lowercased() == "zip" && !set.isMultipart {
                try ArchivePathSafety.validate(zip: main, encoding: encoding)
            }
            try Task.checkCancellation()
            // 临时目录与目标位于同一文件系统，最终移动无需跨卷复制。
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let staging = destination.appendingPathComponent(".mulee-extract-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            temporary = staging
            let rawRoot = staging.appendingPathComponent("raw", isDirectory: true)
            try FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: false)
            progress?(0)
            let extracted = try await SevenZipProcess.run(
                binary: binary, arguments: ["x", "-y", "-bsp1", "-sccUTF-8", "-o" + rawRoot.path] + codePage + ["--", main.path],
                password: successfulPassword, timeout: options.timeout, progress: progress
            )
            guard extracted.status == 0 else { throw Self.classify(extracted.text, multipart: set.isMultipart) }
            try ArchivePathSafety.validateTree(rawRoot)
            var ready = rawRoot
            if main.pathExtension.lowercased() == "zip" && !set.isMultipart {
                let (directory, repaired) = try ZipFilenameRepair.repair(archive: main, rawRoot: rawRoot, listing: listing.text, encoding: encoding)
                ready = directory
                if !repaired { warnings.append("文件名编码未能修复") }
            }
            try ArchivePathSafety.validateTree(ready)
            try Task.checkCancellation()
            let items = try promote(staging: ready, destination: destination)
            try FileManager.default.removeItem(at: staging)
            temporary = nil
            progress?(1)
            var nested: [ExtractionResult] = []
            if options.recursivelyExtract && depth < 3 {
                var processed = Set<String>()
                for item in try archiveCandidates(in: items) {
                    let siblings = try FileManager.default.contentsOfDirectory(atPath: item.deletingLastPathComponent().path)
                    let detected = ArchiveVolumeDetector.detect(filename: item.lastPathComponent, directoryFilenames: siblings)
                    guard let main = detected.mainVolume else { continue }
                    let key = item.deletingLastPathComponent().appendingPathComponent(main).path
                    guard processed.insert(key).inserted else { continue }
                    var childOptions = options
                    childOptions.expectedVolumeNames = nil
                    childOptions.expectedVolumeCount = nil
                    nested.append(await extract(archive: item, destination: item.deletingLastPathComponent(), rules: rules,
                                                sourceURL: sourceURL, options: childOptions, depth: depth + 1, progress: nil))
                }
            }
            let result = ExtractionResult(status: .succeeded, failure: nil, matchedRule: usedSource == nil ? nil : match.matchedRule,
                                          passwordSource: usedSource, encoding: encoding, topLevelItems: items,
                                          originalVolumes: originals, warnings: warnings, nestedResults: nested)
            do { try options.postAction.apply(to: result) }
            catch { warnings.append("解压成功，但原压缩包处理失败：\(error.localizedDescription)") }
            return ExtractionResult(status: .succeeded, failure: nil, matchedRule: result.matchedRule, passwordSource: usedSource,
                                    encoding: encoding, topLevelItems: items, originalVolumes: originals,
                                    warnings: warnings, nestedResults: nested)
        } catch {
            if let temporary {
                do { try FileManager.default.removeItem(at: temporary) }
                catch { warnings.append("临时目录清理失败：\(error.localizedDescription)") }
            }
            let failure: ExtractionFailure
            if error is CancellationError { failure = .cancelled }
            else if let known = error as? ExtractionFailure { failure = known }
            else {
                let nsError = error as NSError
                failure = nsError.code == NSFileWriteOutOfSpaceError || (nsError.domain == NSPOSIXErrorDomain && nsError.code == 28)
                    ? .insufficientSpace : .fileOperation(error.localizedDescription)
            }
            let waiting: Bool
            if case .missingVolumes = failure { waiting = true } else { waiting = false }
            return ExtractionResult(status: waiting ? .waitingForVolumes : .failed, failure: failure,
                                    matchedRule: usedSource == nil ? nil : match.matchedRule, passwordSource: usedSource,
                                    encoding: encoding, topLevelItems: [], originalVolumes: originals,
                                    warnings: warnings, nestedResults: [])
        }
    }

    static func classify(_ text: String, multipart: Bool) -> ExtractionFailure {
        let lower = text.lowercased()
        if lower.contains("no space left") || lower.contains("disk full") || lower.contains("not enough space") { return .insufficientSpace }
        if lower.contains("missing volume") || lower.contains("cannot find volume") ||
            (multipart && (lower.contains("unexpected end") || lower.contains("unavailable start of archive"))) {
            return .missingVolumes([])
        }
        if lower.contains("wrong password") || lower.contains("enter password") || lower.contains("password is incorrect") { return .wrongPasswords }
        return .damagedArchive
    }

    private func promote(staging: URL, destination: URL) throws -> [URL] {
        let items = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
        var moved: [(URL, URL)] = []
        do {
            for item in items {
                var target = destination.appendingPathComponent(item.lastPathComponent)
                var number = 2
                while FileManager.default.fileExists(atPath: target.path) {
                    let ext = item.pathExtension
                    let stem = ext.isEmpty ? item.lastPathComponent : item.deletingPathExtension().lastPathComponent
                    target = destination.appendingPathComponent(stem + " (\(number))" + (ext.isEmpty ? "" : "." + ext))
                    number += 1
                }
                try FileManager.default.moveItem(at: item, to: target)
                moved.append((item, target))
            }
            return moved.map(\.1)
        } catch {
            for (original, target) in moved.reversed() {
                do { try FileManager.default.moveItem(at: target, to: original) }
                catch { throw ExtractionFailure.fileOperation("恢复已移动文件失败：\(error.localizedDescription)") }
            }
            throw error
        }
    }

    private func archiveCandidates(in roots: [URL]) throws -> [URL] {
        var result: [URL] = []
        for root in roots {
            let values = try root.resourceValues(forKeys: [.isDirectoryKey])
            if values.isDirectory == true {
                if let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) {
                    for case let item as URL in enumerator where ArchiveVolumeDetector.detect(filename: item.lastPathComponent, directoryFilenames: []).isArchive {
                        if try item.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true { result.append(item) }
                    }
                }
            } else if ArchiveVolumeDetector.detect(filename: root.lastPathComponent, directoryFilenames: []).isArchive {
                result.append(root)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}

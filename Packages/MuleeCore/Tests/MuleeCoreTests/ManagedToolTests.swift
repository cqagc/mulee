import CryptoKit
import Foundation
import Testing
@testable import MuleeCore

struct ManagedToolTests {
    @Test func checksumFormats() throws {
        let digest = String(repeating: "a", count: 64)
        #expect(try ManagedToolInstaller.checksum(in: "\(digest)  yt-dlp_macos\n", filename: "yt-dlp_macos") == digest)
        #expect(try ManagedToolInstaller.checksum(in: "\(digest.uppercased()) *deno.zip", filename: "deno.zip") == digest)
        #expect(try ManagedToolInstaller.checksum(in: digest, filename: "deno.zip") == digest)
        #expect(throws: EngineError.self) {
            try ManagedToolInstaller.checksum(in: "\(digest)  other", filename: "yt-dlp_macos")
        }
    }

    @Test func verifiedInstallAndAtomicReplacement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedTool-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try #require(URL(string: "https://tools.invalid/tool"))
        let sums = try #require(URL(string: "https://tools.invalid/sums"))
        let tool = ManagedTool(name: "test-tool", downloadURL: url, checksumURL: sums)
        let oldData = Data("#!/bin/sh\necho version-one\n".utf8)
        let newData = Data("#!/bin/sh\necho version-two\n".utf8)
        let old = ManagedToolInstaller(directory: root) { source, destination in
            let bytes = source == url ? oldData : Self.sums(oldData)
            try bytes.write(to: destination)
        }
        let binary = try await old.install(tool)
        #expect(try Data(contentsOf: binary) == oldData)
        #expect(try await old.record(for: tool)?.version == "version-one")
        let heldOpen = try FileHandle(forReadingFrom: binary)
        defer { try? heldOpen.close() }
        let updated = ManagedToolInstaller(directory: root) { source, destination in
            try (source == url ? newData : Self.sums(newData)).write(to: destination)
        }
        #expect(try await updated.install(tool, force: true) == binary)
        #expect(try Data(contentsOf: binary) == newData)
        // 已打开的旧 inode 仍完整，路径指向新文件，证明是 rename 替换。
        #expect(try heldOpen.readToEnd() == oldData)
        #expect(try await updated.record(for: tool)?.version == "version-two")
        #expect(try await updated.installedURL(for: tool) == binary)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["test-tool", "test-tool.json"])
    }

    @Test func checksumFailurePreservesExistingTool() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedTool-bad-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = ManagedTool.ytDlp()
        let payload = Data("#!/bin/sh\necho original\n".utf8)
        let valid = ManagedToolInstaller(directory: root) { source, destination in
            let data = source == tool.downloadURL ? payload : Self.sums(payload, filename: "yt-dlp_macos")
            try data.write(to: destination)
        }
        let binary = try await valid.install(tool)
        let record = try await valid.record(for: tool)
        let invalid = ManagedToolInstaller(directory: root) { source, destination in
            let data = source == tool.downloadURL ? Data("bad payload".utf8) : Self.sums(payload, filename: "yt-dlp_macos")
            try data.write(to: destination)
        }
        await #expect(throws: EngineError.self) { try await invalid.install(tool, force: true) }
        #expect(try Data(contentsOf: binary) == payload)
        #expect(try await valid.record(for: tool) == record)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).allSatisfy { !$0.hasPrefix(".install-") })
        let empty = ManagedToolInstaller(directory: root.appendingPathComponent("empty")) { _, destination in
            try Data("invalid".utf8).write(to: destination)
        }
        await #expect(throws: EngineError.self) { try await empty.install(tool) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("empty/" + tool.name).path))
    }

    @Test func zipInstallsOnlyNamedExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ManagedTool-zip-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("deno")
        try Data("#!/bin/sh\necho deno-test-version\n".utf8).write(to: executable)
        let archive = root.appendingPathComponent("deno.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.arguments = ["-j", archive.path, executable.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        try #require(process.terminationStatus == 0)
        let bytes = try Data(contentsOf: archive)
        let tool = try ManagedTool(
            name: "deno", downloadURL: #require(URL(string: "https://tools.invalid/deno.zip")),
            checksumURL: #require(URL(string: "https://tools.invalid/deno.zip.sha256sum")),
            extraction: .zip(entry: "deno")
        )
        let installer = ManagedToolInstaller(directory: root.appendingPathComponent("bin")) { url, destination in
            try (url == tool.downloadURL ? bytes : Self.sums(bytes, filename: "deno.zip")).write(to: destination)
        }
        let binary = try await installer.install(tool)
        #expect(try Data(contentsOf: binary) == Data(contentsOf: executable))
        #expect(FileManager.default.isExecutableFile(atPath: binary.path))
        #expect(try await installer.record(for: tool)?.version == "deno-test-version")
    }

    private static func sums(_ data: Data, filename: String = "tool") -> Data {
        let hex = SHA256.hash(data: data).map { byte in
            let hex = String(byte, radix: 16)
            return byte < 0x10 ? "0" + hex : hex
        }.joined()
        return Data("\(hex)  \(filename)\n".utf8)
    }
}

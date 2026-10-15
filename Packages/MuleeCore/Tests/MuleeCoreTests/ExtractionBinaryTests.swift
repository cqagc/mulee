import Foundation
import Testing
@testable import MuleeCore

struct ExtractionBinaryTests {
    @Test("显式路径、App 内置工具、环境变量按顺序查找，缺失时不回退到 Homebrew")
    func lookupOrder() async throws {
        try await ExtractionFixture.withFixture { fixture in
            let bundle = fixture.root.appendingPathComponent("Mulee.app", isDirectory: true)
            let bundled = bundle.appendingPathComponent("Contents/Helpers/7zz")
            try FileManager.default.createDirectory(at: bundled.deletingLastPathComponent(), withIntermediateDirectories: true)
            let explicit = try fixture.file("explicit-7zz")
            let override = try fixture.file("override-7zz")
            try Data("fixture".utf8).write(to: bundled)
            for binary in [explicit, bundled, override] {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
            }
            let environment = ["MULEE_7ZZ": override.path]
            #expect(SevenZipProcess.locate(explicitURL: explicit, bundleURL: bundle, environment: environment) == explicit)
            #expect(SevenZipProcess.locate(explicitURL: nil, bundleURL: bundle, environment: environment) == bundled)
            try FileManager.default.removeItem(at: explicit)
            #expect(SevenZipProcess.locate(explicitURL: explicit, bundleURL: bundle, environment: environment) == bundled)
            try FileManager.default.removeItem(at: bundled)
            #expect(SevenZipProcess.locate(explicitURL: nil, bundleURL: bundle, environment: environment) == override)
            #expect(SevenZipProcess.locate(explicitURL: nil, bundleURL: bundle, environment: [:]) == nil)
            #expect(SevenZipProcess.locate(explicitURL: nil, bundleURL: bundle, environment: ["MULEE_7ZZ": ""]) == nil)
            #expect(SevenZipProcess.locate(explicitURL: fixture.root, bundleURL: bundle, environment: [:]) == nil)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: override.path)
            #expect(SevenZipProcess.locate(explicitURL: nil, bundleURL: bundle, environment: environment) == nil)
        }
    }
}

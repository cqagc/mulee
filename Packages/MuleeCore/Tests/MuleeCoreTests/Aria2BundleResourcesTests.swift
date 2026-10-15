import Foundation
import Testing
@testable import MuleeCore

/// 从 App 包内启动 aria2c 时要带上 OpenSSL 模块目录和根证书；从 Homebrew 启动时不加。
@Suite struct Aria2BundleResourcesTests {
    private func makeBundle(withResources: Bool) throws -> (root: URL, binary: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "mulee-bundle-\(UUID().uuidString)", directoryHint: .isDirectory)
        let contents = root.appending(path: "Mulee.app/Contents", directoryHint: .isDirectory)
        let binary = contents.appending(path: "Helpers/aria2c")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: binary.path, contents: Data())
        if withResources {
            try FileManager.default.createDirectory(at: contents.appending(path: "Frameworks/aria2/ossl-modules"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: contents.appending(path: "Resources/aria2"), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: contents.appending(path: "Resources/aria2/cert.pem").path, contents: Data("pem".utf8))
        }
        return (root, binary)
    }

    @Test func bundledBinaryGetsModulesAndCertificate() throws {
        let bundle = try makeBundle(withResources: true)
        defer { try? FileManager.default.removeItem(at: bundle.root) }

        let resources = Aria2BundleResources.resolve(binary: bundle.binary)
        var environment: [String: String] = [:]
        resources.apply(to: &environment)

        let modules = try #require(environment["OPENSSL_MODULES"])
        #expect(modules.hasSuffix("Contents/Frameworks/aria2/ossl-modules"))
        let argument = try #require(resources.additionalArguments.first)
        #expect(argument.hasPrefix("--ca-certificate="))
        #expect(argument.hasSuffix("Contents/Resources/aria2/cert.pem"))
    }

    @Test func bundleWithoutResourcesAddsNothing() throws {
        let bundle = try makeBundle(withResources: false)
        defer { try? FileManager.default.removeItem(at: bundle.root) }

        let resources = Aria2BundleResources.resolve(binary: bundle.binary)
        #expect(resources == Aria2BundleResources())
        #expect(resources.additionalArguments.isEmpty)
    }

    @Test func homebrewBinaryAddsNothing() {
        let resources = Aria2BundleResources.resolve(binary: URL(filePath: "/opt/homebrew/bin/aria2c"))
        #expect(resources == Aria2BundleResources())
    }
}

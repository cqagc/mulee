import Foundation
import Testing
@testable import MuleeCore

struct ExtractionKeychainTests {
    @Test("真实钥匙串按唯一标识写入、更新、读取、删除", .enabled(if: ProcessInfo.processInfo.environment["MULEE_UNZIP_KEYCHAIN_TESTS"] == "1"))
    func roundTrip() async throws {
        let provider = KeychainPasswordProvider()
        let id = "mulee-unzip-test-" + UUID().uuidString
        do {
            try await provider.setPassword("first", for: id)
            #expect(try await provider.password(for: id) == "first")
            try await provider.setPassword("second", for: id)
            #expect(try await provider.password(for: id) == "second")
            try await provider.setPassword(nil, for: id)
            #expect(try await provider.password(for: id) == nil)
        } catch {
            try await provider.setPassword(nil, for: id)
            throw error
        }
    }
}

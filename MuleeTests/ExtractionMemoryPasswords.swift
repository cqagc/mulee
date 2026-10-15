import MuleeCore
@testable import Mulee

actor ExtractionMemoryPasswords: ExtractionPasswordStoring {
    private(set) var passwords: [String: String] = [:]
    private var book: [String] = []
    var failsWrites = false

    func password(for keychainItemID: String) async throws -> String? {
        passwords[keychainItemID]
    }

    func passwordBook() async throws -> [String] { book }

    func setPassword(_ password: String?, for keychainItemID: String) async throws {
        if failsWrites { throw ExtractionFailure.passwordStorage }
        passwords[keychainItemID] = password
    }

    func setPasswordBook(_ passwords: [String]) async throws {
        if failsWrites { throw ExtractionFailure.passwordStorage }
        book = passwords
    }

    func failWrites() {
        failsWrites = true
    }
}

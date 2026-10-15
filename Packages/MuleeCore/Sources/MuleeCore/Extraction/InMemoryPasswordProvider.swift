import Foundation

public struct InMemoryPasswordProvider: PasswordProviding {
    private let passwords: [String: String]
    private let book: [String]

    public init(passwords: [String: String] = [:], passwordBook: [String] = []) {
        self.passwords = passwords
        self.book = passwordBook
    }

    public func password(for keychainItemID: String) async throws -> String? {
        passwords[keychainItemID]
    }

    public func passwordBook() async throws -> [String] { book }
}

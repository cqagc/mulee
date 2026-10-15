import Foundation

public protocol PasswordProviding: Sendable {
    func password(for keychainItemID: String) async throws -> String?
    func passwordBook() async throws -> [String]
}

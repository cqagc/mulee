import Foundation
import LocalAuthentication
import Security

public actor KeychainPasswordProvider: PasswordProviding {
    public static let service = "com.cqagc.mulee.unzip"
    private static let bookAccount = "mulee.password-book"

    public init() {}

    public func password(for keychainItemID: String) async throws -> String? {
        guard let data = try read(account: keychainItemID) else { return nil }
        guard let value = String(data: data, encoding: .utf8) else { throw ExtractionFailure.passwordStorage }
        return value
    }

    public func passwordBook() async throws -> [String] {
        guard let data = try read(account: Self.bookAccount) else { return [] }
        return try JSONDecoder().decode([String].self, from: data)
    }

    public func setPassword(_ password: String?, for keychainItemID: String) throws {
        guard keychainItemID != Self.bookAccount else { throw ExtractionFailure.passwordStorage }
        try store(password.map { Data($0.utf8) }, account: keychainItemID)
    }

    public func setPasswordBook(_ passwords: [String]) throws {
        try store(JSONEncoder().encode(passwords), account: Self.bookAccount)
    }

    private func query(account: String) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: Self.service,
                kSecAttrAccount as String: account,
                kSecUseDataProtectionKeychain as String: true,
                kSecAttrSynchronizable as String: false,
                kSecUseAuthenticationContext as String: context]
    }

    private func read(account: String) throws -> Data? {
        var query = query(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw ExtractionFailure.passwordStorage }
        return data
    }

    private func store(_ data: Data?, account: String) throws {
        let query = query(account: account)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw ExtractionFailure.passwordStorage }
            return
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            if added == errSecDuplicateItem {
                guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecSuccess else {
                    throw ExtractionFailure.passwordStorage
                }
            } else if added != errSecSuccess {
                throw ExtractionFailure.passwordStorage
            }
        } else if status != errSecSuccess {
            throw ExtractionFailure.passwordStorage
        }
    }
}

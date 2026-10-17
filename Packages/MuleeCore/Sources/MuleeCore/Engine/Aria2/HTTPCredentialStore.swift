import Foundation
import Security

/// 同步方法由引擎 actor 或后台任务调用，避免钥匙串 IPC 阻塞主线程。
public enum HTTPCredentialStore {
    public static let httpService = "com.cqagc.mulee.http-auth"
    public static let proxyService = "com.cqagc.mulee.proxy"

    public struct Credential: Codable, Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        public let username: String
        public let password: String

        public init(username: String, password: String) {
            self.username = username
            self.password = password
        }

        public var description: String { "Credential(redacted)" }
        public var debugDescription: String { description }

        public var authorization: String {
            "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        }
    }

    public static func save(_ credential: Credential, host: String, service: String = httpService) throws {
        guard !host.isEmpty, !credential.username.contains(":"),
              ![host, credential.username, credential.password].contains(where: {
                  $0.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
              }) else { throw EngineError.invalidResponse(String(localized: "账号或密码包含无效字符", bundle: .module)) }
        let query = query(host: host, service: service)
        let data = try JSONEncoder().encode(credential)
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary))
        } else { try check(status) }
    }

    public static func load(host: String, service: String = httpService) throws -> Credential? {
        var query = query(host: host, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data else { throw EngineError.invalidResponse(String(localized: "无法读取已保存的账号", bundle: .module)) }
        return try JSONDecoder().decode(Credential.self, from: data)
    }

    public static func delete(host: String, service: String = httpService) throws {
        let status = SecItemDelete(query(host: host, service: service) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private static func query(host: String, service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: host.lowercased(),
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private static func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw EngineError.invalidResponse(String(localized: "账号钥匙串访问失败（\(status)）", bundle: .module)) }
    }
}

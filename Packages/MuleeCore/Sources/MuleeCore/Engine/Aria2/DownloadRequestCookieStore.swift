import Foundation
import Security

/// 独立 actor 避免钥匙串 IPC 阻塞界面；账户名固定为 App 任务 ID。
public actor DownloadRequestCookieStore {
    public static let shared = DownloadRequestCookieStore()
    public static let service = "com.cqagc.mulee.request-cookies"

    public init() {}

    public func save(_ cookie: String, taskID: UUID) throws {
        let query = query(taskID)
        var item = query
        item[kSecValueData as String] = Data(cookie.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        if status == errSecDuplicateItem {
            try check(SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(cookie.utf8)] as CFDictionary))
        } else {
            try check(status)
        }
    }

    public func load(taskID: UUID) throws -> String? {
        var query = query(taskID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw EngineError.invalidResponse("无法读取下载 Cookie")
        }
        return value
    }

    public func delete(taskID: UUID) throws {
        let status = SecItemDelete(query(taskID) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func query(_ taskID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: taskID.uuidString,
            kSecUseDataProtectionKeychain as String: true
        ]
    }

    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            // 不携带查询内容或 Cookie；锁定等错误保留原项目，供稍后重试。
            throw EngineError.invalidResponse("下载 Cookie 钥匙串访问失败（\(status)）")
        }
    }
}

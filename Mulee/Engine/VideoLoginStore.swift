import Foundation
import MuleeCore
import Security

/// 主 App 与 Chrome 命令行宿主使用相同的 App 身份访问钥匙串。
actor VideoLoginStore {
    static let shared = VideoLoginStore()
    private let service = "com.cqagc.mulee.video-login"
    private let fallbackDirectory: URL

    init(fallbackDirectory: URL = URL.applicationSupportDirectory.appendingPathComponent("Mulee/VideoLogin", isDirectory: true)) {
        self.fallbackDirectory = fallbackDirectory
    }

    func save(_ request: VideoCookieRequest) throws {
        try request.validateForSaving()
        let data = try JSONEncoder().encode(request)
        _ = try VideoCookieRequest.parse(data)
        let base = query(request.site)
        let attributes: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var add = base
        add.merge(attributes) { _, new in new }
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem { status = SecItemUpdate(base as CFDictionary, attributes as CFDictionary) }
        if status == errSecMissingEntitlement {
            try saveFallback(request)
            return
        }
        guard status == errSecSuccess else { throw failure(status) }
        try removeFallback(request.site)
    }

    func cookies(for site: VideoSite) throws -> [VideoCookie] {
        guard site != .other else { return [] }
        try importHandoff(site)
        return try load(site)?.cookies ?? []
    }

    func updatedAt(for site: VideoSite) throws -> Date? {
        try importHandoff(site)
        guard let request = try load(site), !request.cookies.isEmpty else { return nil }
        var query = query(site)
        query[kSecReturnAttributes] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecMissingEntitlement {
            return try FileManager.default.attributesOfItem(atPath: fallbackFile(site).path)[.modificationDate] as? Date
        }
        guard status == errSecSuccess, let attributes = result as? [CFString: Any] else { throw failure(status) }
        return attributes[kSecAttrModificationDate] as? Date
    }

    func clear(_ site: VideoSite) throws {
        // 先取走 Safari 尚未导入的交接，防止清除后又恢复旧凭据。
        if let directory = try? VideoCookieHandoff.directory(),
           let pending = try VideoCookieHandoff.take(site: site, directory: directory) {
            try FileManager.default.removeItem(at: pending.file)
        }
        let status = SecItemDelete(query(site) as CFDictionary)
        guard [errSecSuccess, errSecItemNotFound, errSecMissingEntitlement].contains(status) else { throw failure(status) }
        try removeFallback(site)
    }

    private func importHandoff(_ site: VideoSite) throws {
        // 没有 App Group 授权的临时签名构建不读取其他路径。
        guard let directory = try? VideoCookieHandoff.directory(),
              let pending = try VideoCookieHandoff.take(site: site, directory: directory) else { return }
        do {
            try save(pending.request)
            try FileManager.default.removeItem(at: pending.file)
        } catch {
            // 保留 0600 交接供下次导入；不在钥匙串暂不可用时丢失凭据。
            try VideoCookieHandoff.save(pending.request, directory: directory)
            try FileManager.default.removeItem(at: pending.file)
            throw error
        }
    }

    private func load(_ site: VideoSite) throws -> VideoCookieRequest? {
        var query = query(site)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound || status == errSecMissingEntitlement { return try loadFallback(site) }
        guard status == errSecSuccess, let data = result as? Data else { throw failure(status) }
        return try VideoCookieRequest.parse(data)
    }

    /// 无描述文件签名可能没有 data protection keychain 访问组；仅此错误回退。
    /// 使用与 Safari 交接相同的原子写入，文件创建时即为 0600。
    func saveFallback(_ request: VideoCookieRequest) throws {
        try request.validateForSaving()
        try FileManager.default.createDirectory(
            at: fallbackDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        try VideoCookieHandoff.save(request, directory: fallbackDirectory)
    }

    func loadFallback(_ site: VideoSite) throws -> VideoCookieRequest? {
        let file = fallbackFile(site)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= VideoCookieRequest.maximumBytes else {
            throw EngineError.invalidResponse(String(localized: "无法读取浏览器登录状态"))
        }
        let request = try VideoCookieRequest.parse(Data(contentsOf: file))
        guard request.site == site else { throw EngineError.unsupportedLink }
        return request
    }

    func removeFallback(_ site: VideoSite) throws {
        let file = fallbackFile(site)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }

    private func fallbackFile(_ site: VideoSite) -> URL {
        fallbackDirectory.appendingPathComponent(site.rawValue + ".json")
    }

    private func query(_ site: VideoSite) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: site.rawValue, kSecUseDataProtectionKeychain: true,
         kSecAttrSynchronizable: false]
    }

    private func failure(_ status: OSStatus) -> EngineError {
        .invalidResponse(String(localized: "无法访问视频登录状态的钥匙串（\(status)）"))
    }
}

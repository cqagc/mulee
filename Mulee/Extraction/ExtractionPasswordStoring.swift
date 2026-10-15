import MuleeCore

/// 密码读取与写入均可替换为内存实现；正式运行只使用钥匙串。
nonisolated protocol ExtractionPasswordStoring: PasswordProviding {
    func setPassword(_ password: String?, for keychainItemID: String) async throws
    func setPasswordBook(_ passwords: [String]) async throws
}

extension KeychainPasswordProvider: ExtractionPasswordStoring {}

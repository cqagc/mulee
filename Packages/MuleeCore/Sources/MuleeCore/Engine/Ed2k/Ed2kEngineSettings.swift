/// 电驴网络专用设置；限速单位为字节/秒，0 表示不限速。
public struct Ed2kEngineSettings: Sendable, Hashable {
    public var tcpPort: UInt16
    public var udpPort: UInt16
    public var connectToServers: Bool
    public var enableKad: Bool
    public var uploadLimit: Int64
    public var shareCompletedFiles: Bool
    public var obfuscation: Bool

    public init(
        tcpPort: UInt16 = 4662,
        udpPort: UInt16 = 4672,
        connectToServers: Bool = true,
        enableKad: Bool = true,
        uploadLimit: Int64 = 0,
        shareCompletedFiles: Bool = true,
        obfuscation: Bool = true
    ) {
        self.tcpPort = tcpPort
        self.udpPort = udpPort
        self.connectToServers = connectToServers
        self.enableKad = enableKad
        self.uploadLimit = uploadLimit
        self.shareCompletedFiles = shareCompletedFiles
        self.obfuscation = obfuscation
    }

    func validate() throws {
        guard tcpPort > 0, udpPort > 0, uploadLimit >= 0 else {
            throw ECError.rejected("TCP / UDP 端口须为 1–65535，上传限速不能小于 0")
        }
    }
}

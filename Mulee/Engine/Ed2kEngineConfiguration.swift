import MuleeCore

/// 电驴专用设置；通用目录和下载限速由 EngineOptions 下发。
enum Ed2kEngineConfiguration {
    static func configuration(from settings: SettingsModel) -> Ed2kEngineSettings {
        Ed2kEngineSettings(
            tcpPort: UInt16(clamping: max(1, settings.ed2kTCPPort)),
            udpPort: UInt16(clamping: max(1, settings.ed2kUDPPort)),
            connectToServers: settings.ed2kConnectToServers,
            enableKad: settings.ed2kEnableKad,
            uploadLimit: EngineOptionsMapper.options(from: settings).uploadLimit,
            shareCompletedFiles: settings.ed2kShare,
            obfuscation: settings.ed2kObfuscation
        )
    }
}

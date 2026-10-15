import MuleeCore

/// 电驴专用设置；通用目录和下载限速由 EngineOptions 下发。
enum Ed2kEngineConfiguration {
    static func configuration(from settings: SettingsModel) -> Ed2kEngineSettings {
        Ed2kEngineSettings(
            tcpPort: UInt16(clamping: max(1, settings.ed2kTCPPort)),
            udpPort: UInt16(clamping: max(1, settings.ed2kUDPPort)),
            connectToServers: settings.ed2kConnectToServers,
            enableKad: settings.ed2kEnableKad,
            // 上传额度由协调器统一分配，专用设置不覆盖它。
            uploadLimit: 0,
            shareCompletedFiles: settings.ed2kShare,
            obfuscation: settings.ed2kObfuscation
        )
    }
}

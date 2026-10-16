import MuleeCore

/// BT 设置的值映射；通用目录与限速仍由 EngineOptions 下发。
enum BitTorrentEngineConfiguration {
    static func configuration(from settings: SettingsModel) -> TorrentEngineSettings {
        var configuration = TorrentEngineSettings(
            listenPort: min(65535, max(0, settings.btPort)),
            portMapping: settings.portMapping,
            seedingAction: settings.seedingAction == .stop ? .stop : .slowDown,
            exemptPrivateTorrents: settings.privateIgnoresRatio
        )
        // Match aria2's M suffix (MiB); SettingsModel constrains the slider to 32...512.
        configuration.diskCacheBytes = Int64(min(512, max(0, settings.diskCacheMB))) * 1_048_576
        return configuration
    }
}

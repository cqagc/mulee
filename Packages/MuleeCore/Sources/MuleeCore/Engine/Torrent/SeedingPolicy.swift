enum SeedingPolicy: Sendable {
    static func action(
        ratio: Double,
        isFinished: Bool,
        isPrivate: Bool,
        paused: Bool,
        uploadLimit: Int64,
        settings: TorrentEngineSettings,
        seedTimeSeconds: Int64 = 0,
        seedInactiveSeconds: Int64 = 0
    ) -> SeedingPolicyAction {
        // 历史完成时间、分享率或全局 progress 均不能代替所选内容完成状态。
        guard isFinished else { return .none }
        func reached(_ minutes: Int, seconds: Int64) -> Bool {
            minutes > 0 && seconds >= 0 && seconds / 60 >= Int64(minutes)
        }
        if isPrivate && settings.privateMinSeedMinutes > 0
            && !reached(settings.privateMinSeedMinutes, seconds: seedTimeSeconds) { return .none }
        let ratioReached = ratio.isFinite && ratio >= 1 && !(isPrivate && settings.exemptPrivateTorrents)
        guard ratioReached || reached(settings.seedTimeLimitMinutes, seconds: seedTimeSeconds)
            || reached(settings.seedInactiveLimitMinutes, seconds: seedInactiveSeconds) else { return .none }
        switch settings.seedingAction {
        case .remove:
            return .remove
        case .stop:
            return paused ? .none : .pause
        case .slowDown:
            return uploadLimit == 51_200 ? .none : .setUploadLimit(51_200)
        }
    }
}

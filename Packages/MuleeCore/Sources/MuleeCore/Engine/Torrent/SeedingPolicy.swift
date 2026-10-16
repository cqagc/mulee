enum SeedingPolicy: Sendable {
    static func action(
        ratio: Double,
        isFinished: Bool,
        isPrivate: Bool,
        paused: Bool,
        uploadLimit: Int64,
        settings: TorrentEngineSettings
    ) -> SeedingPolicyAction {
        // 历史完成时间、分享率或全局 progress 均不能代替所选内容完成状态。
        guard isFinished, ratio.isFinite, ratio >= 1,
              !(isPrivate && settings.exemptPrivateTorrents) else { return .none }
        switch settings.seedingAction {
        case .stop:
            return paused ? .none : .pause
        case .slowDown:
            return uploadLimit == 51_200 ? .none : .setUploadLimit(51_200)
        }
    }
}

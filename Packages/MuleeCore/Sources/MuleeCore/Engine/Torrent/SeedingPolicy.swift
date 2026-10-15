enum SeedingPolicy: Sendable {
    static func action(
        ratio: Double,
        isPrivate: Bool,
        paused: Bool,
        uploadLimit: Int64,
        settings: TorrentEngineSettings
    ) -> SeedingPolicyAction {
        guard ratio.isFinite, ratio >= 1,
              !(isPrivate && settings.exemptPrivateTorrents) else { return .none }
        switch settings.seedingAction {
        case .stop:
            return paused ? .none : .pause
        case .slowDown:
            return uploadLimit == 51_200 ? .none : .setUploadLimit(51_200)
        }
    }
}

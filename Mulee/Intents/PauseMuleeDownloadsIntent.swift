import AppIntents

struct PauseMuleeDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "暂停全部"
    @Dependency var actions: MuleeIntentActions

    @MainActor
    func perform() async throws -> some IntentResult {
        actions.pauseAll()
        return .result()
    }
}

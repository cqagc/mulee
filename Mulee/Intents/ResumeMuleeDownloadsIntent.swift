import AppIntents

struct ResumeMuleeDownloadsIntent: AppIntent {
    static let title: LocalizedStringResource = "继续全部"
    @Dependency var actions: MuleeIntentActions

    @MainActor
    func perform() async throws -> some IntentResult {
        actions.resumeAll()
        return .result()
    }
}

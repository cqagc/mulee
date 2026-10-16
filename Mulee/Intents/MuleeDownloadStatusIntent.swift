import AppIntents

struct MuleeDownloadStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "获取下载状态"
    @Dependency var actions: MuleeIntentActions

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let summary = actions.status().summary
        return .result(value: summary, dialog: "\(summary)")
    }
}

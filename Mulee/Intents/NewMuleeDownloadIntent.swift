import AppIntents

struct NewMuleeDownloadIntent: AppIntent {
    static let title: LocalizedStringResource = "新建下载"
    static let description = IntentDescription("打开预填的新建下载面板，确认后才开始下载。")
    static let openAppWhenRun = true

    @Parameter(title: "链接") var link: String
    @Parameter(title: "保存目录") var directory: String?
    @Dependency var actions: MuleeIntentActions

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try actions.prefill(link: link, directory: directory)
        return .result(dialog: "请在 Mulee 的新建下载面板中确认。")
    }
}

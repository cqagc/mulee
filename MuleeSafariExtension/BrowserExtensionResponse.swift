import Foundation
import SafariServices

/// The native callback transfers this context exactly once to the MainActor task.
/// No caller accesses the context after creating this adapter; completion is actor
/// isolated. Remove this adapter when the SDK makes NSExtensionContext Sendable.
nonisolated final class BrowserExtensionResponse: @unchecked Sendable {
    private let context: NSExtensionContext

    init(context: NSExtensionContext) {
        self.context = context
    }

    @MainActor func complete(opened: Bool) {
        let reply = NSExtensionItem()
        reply.userInfo = [SFExtensionMessageKey: ["ok": opened]]
        context.completeRequest(returningItems: [reply])
    }
}

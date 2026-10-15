import AppKit
import SafariServices

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    nonisolated func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey]
        // Extract a Sendable value before moving the native request onto the UI actor.
        let value = (message as? [String: Any]).flatMap { object -> String? in
            guard object.count == 1 else { return nil }
            return object["url"] as? String
        }
        let response = BrowserExtensionResponse(context: context)
        Task { @MainActor in
            let url = BrowserExtensionRequest.validatedURL(from: value.map { ["url": $0] })
            let opened = url.map { NSWorkspace.shared.open($0) } ?? false
            response.complete(opened: opened)
        }
    }
}

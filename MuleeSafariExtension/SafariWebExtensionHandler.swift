import AppKit
import SafariServices
import MuleeCore

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    nonisolated func beginRequest(with context: NSExtensionContext) {
        let message = (context.inputItems.first as? NSExtensionItem)?.userInfo?[SFExtensionMessageKey]
        // Extract a Sendable value before moving the native request onto the UI actor.
        let value = (message as? [String: Any]).flatMap { object -> String? in
            guard object.count == 1 else { return nil }
            return object["url"] as? String
        }
        let cookieData = (message as? [String: Any]).flatMap { object -> Data? in
            guard ["videoCookies", "downloadCookies"].contains(object["type"] as? String ?? ""),
                  JSONSerialization.isValidJSONObject(object) else { return nil }
            return try? JSONSerialization.data(withJSONObject: object)
        }
        let response = BrowserExtensionResponse(context: context)
        Task { @MainActor in
            if let cookieData {
                do {
                    let type = (try JSONSerialization.jsonObject(with: cookieData) as? [String: Any])?["type"] as? String
                    if type == "downloadCookies" {
                        let request = try DownloadCookieRequest.parse(cookieData)
                        try DownloadCookieHandoff.save(request, directory: DownloadCookieHandoff.directory())
                    } else {
                        let request = try VideoCookieRequest.parse(cookieData)
                        try VideoCookieHandoff.save(request, directory: VideoCookieHandoff.directory())
                    }
                    response.complete(opened: true)
                } catch {
                    response.complete(opened: false)
                }
                return
            }
            let url = BrowserExtensionRequest.validatedURL(from: value.map { ["url": $0] })
            let opened = url.map { NSWorkspace.shared.open($0) } ?? false
            response.complete(opened: opened)
        }
    }
}

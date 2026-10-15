import Foundation

/// Native messages follow the same boundary and parser as the app's URL entry.
@MainActor enum BrowserExtensionRequest {
    static func validatedURL(from message: Any?) -> URL? {
        guard let object = message as? [String: Any], object.count == 1,
              let value = object["url"] as? String,
              value.utf8.count <= OpenURLRequest.maximumBytes,
              let url = URL(string: value), url.scheme == "mulee",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems,
              items.allSatisfy({ ["url", "referrer", "text"].contains($0.name) && $0.value != nil }),
              items.filter({ $0.name == "referrer" }).count <= 1,
              items.filter({ $0.name == "text" }).count <= 1,
              OpenURLRequest.parse(url, detectPagePassword: false) != nil else { return nil }
        return url
    }
}

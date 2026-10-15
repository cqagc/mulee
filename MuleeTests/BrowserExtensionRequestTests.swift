import Foundation
import Testing
@testable import Mulee

@Suite @MainActor struct BrowserExtensionRequestTests {
    private func entry(_ values: [String], text: String? = nil) throws -> String {
        var components = URLComponents()
        components.scheme = "mulee"
        components.host = "add"
        components.queryItems = values.map { URLQueryItem(name: "url", value: $0) }
        if let text { components.queryItems?.append(URLQueryItem(name: "text", value: text)) }
        return try #require(components.string)
    }

    @Test func acceptsOnlyValidatedAddMessages() throws {
        let value = try entry(["https://example.org/Sintel.zip"], text: "密码：abc123")
        let result = BrowserExtensionRequest.validatedURL(from: ["url": value])
        #expect(result?.absoluteString == value)
        #expect(BrowserExtensionRequest.validatedURL(from: value) == nil)
        #expect(BrowserExtensionRequest.validatedURL(from: ["url": value, "cookies": "private"]) == nil)
        #expect(BrowserExtensionRequest.validatedURL(from: ["url": 42]) == nil)
    }

    @Test(arguments: ["file:///tmp/private.torrent", "/tmp/private.torrent", "javascript:alert(1)",
                      "https://example.org/a.zip\nfile:///tmp/private.torrent"])
    func rejectsUnsafeLinks(_ value: String) throws {
        let message = ["url": try entry([value])]
        #expect(BrowserExtensionRequest.validatedURL(from: message) == nil)
    }

    @Test func rejectsLocalThunderAndMixedInput() throws {
        let thunder = "thunder://" + Data("AAfile:///tmp/private.torrentZZ".utf8).base64EncodedString()
        let message = ["url": try entry(["https://example.org/a.zip", thunder])]
        #expect(BrowserExtensionRequest.validatedURL(from: message) == nil)
    }

    @Test(arguments: ["mulee://start?url=https://example.org/a.zip",
                      "mulee://add/path?url=https://example.org/a.zip",
                      "mulee://user@add?url=https://example.org/a.zip",
                      "mulee://add:123?url=https://example.org/a.zip",
                      "mulee://add?url=https://example.org/a.zip#fragment",
                      "mulee://add?url=https://example.org/a.zip&cookie=private",
                      "mulee://add?url=https://example.org/a.zip&text=a&text=b",
                      "https://example.org/"])
    func rejectsCommandsAndUnexpectedFields(_ value: String) {
        #expect(BrowserExtensionRequest.validatedURL(from: ["url": value]) == nil)
    }

    @Test func appliesAppCountAndEncodedByteLimits() throws {
        let values = (0..<200).map { "https://example.org/\($0).zip" }
        #expect(BrowserExtensionRequest.validatedURL(from: ["url": try entry(values)]) != nil)
        #expect(BrowserExtensionRequest.validatedURL(from: ["url": try entry(values + ["https://example.org/last.zip"])]) == nil)
        let oversized = try entry([values[0]], text: String(repeating: "a", count: 1_048_576))
        #expect(BrowserExtensionRequest.validatedURL(from: ["url": oversized]) == nil)
    }
}

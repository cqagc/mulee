import AppKit
import Testing
@testable import Mulee

@Suite @MainActor struct ServicesTests {
    @Test func selectedTextOpensOneDraftWithoutDownloading() {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel())
        #expect(router.openSelectedText("下载：https://example.org/Ubuntu.iso\nhttps://example.org/Sintel.torrent"))
        #expect(model.isShowingNewTask)
        #expect(model.pendingNewTaskText == "https://example.org/Ubuntu.iso\nhttps://example.org/Sintel.torrent")
        #expect(model.tasks.isEmpty)
    }

    @Test func acceptsMagnetEd2kAndThunderSelections() {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel())
        let magnet = "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c"
        let ed2k = "ed2k://|file|Sintel archive.zip|1024|9F3A0C5E7D21B84A6C0E93F15B71DC21|/"
        let thunder = "thunder://" + Data("AAhttps://example.org/Sintel.zipZZ".utf8).base64EncodedString()
        #expect(router.openSelectedText([magnet, ed2k, thunder].joined(separator: "\n")))
        #expect(model.pendingNewTaskText.split(separator: "\n").count == 3)
        #expect(model.tasks.isEmpty)
    }

    @Test func bundleAdvertisesServiceAndLocalizedNames() throws {
        let services = try #require(Bundle.main.infoDictionary?["NSServices"] as? [[String: Any]])
        let service = try #require(services.first)
        #expect(service["NSMessage"] as? String == "downloadWithMulee")
        #expect((service["NSMenuItem"] as? [String: String])?["default"] == "用 Mulee 下载")
        for (language, expected) in [("zh-Hans", "用 Mulee 下载"), ("en", "Download with Mulee"), ("zh-Hant", "使用 Mulee 下載")] {
            let path = try #require(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try #require(Bundle(path: path))
            #expect(bundle.localizedString(forKey: "用 Mulee 下载", value: nil, table: "ServicesMenu") == expected)
        }
    }

    @Test func rejectsUnsupportedLocalAndOversizedText() {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel())
        for text in ["普通文字", "file:///tmp/private.torrent", "/tmp/private.torrent", String(repeating: "a", count: OpenURLRequest.maximumBytes + 1)] {
            #expect(!router.openSelectedText(text))
        }
        #expect(!router.openSelectedText((0...OpenURLRequest.maximumLinks).map { "https://example.org/\($0).zip" }.joined(separator: "\n")))
        #expect(!model.isShowingNewTask)
        #expect(model.tasks.isEmpty)
    }

    @Test func serviceAcceptsURLPasteboardAndReportsInvalidText() throws {
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let provider = DownloadServicesProvider(router: OpenURLRouter(model: model, settings: SettingsModel()))
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString("https://example.org/Ubuntu.iso", forType: .URL)
        var error: NSString?
        provider.downloadWithMulee(pasteboard, userData: nil, error: &error)
        #expect(error == nil)
        #expect(model.isShowingNewTask)
        #expect(model.tasks.isEmpty)
        pasteboard.clearContents()
        pasteboard.setString("无链接", forType: .string)
        provider.downloadWithMulee(pasteboard, userData: nil, error: &error)
        #expect(error != nil)
    }
}

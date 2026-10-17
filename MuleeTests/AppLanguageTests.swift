import AppKit
import SwiftUI
import Testing
@testable import Mulee

@Suite @MainActor struct AppLanguageTests {
    @Test func pickerOptionsAndCodes() {
        #expect(AppLanguage.allCases.map(\.rawValue) == ["", "zh-Hans", "zh-Hant", "en", "ja"])
        #expect(AppLanguage.allCases.dropFirst().map(\.nativeName) == ["简体中文", "繁體中文", "English", "日本語"])
    }

    @Test func readsAndWritesApplicationDomain() throws {
        let temporary = try TemporaryDefaults(prefix: "language.")
        defer { temporary.clean() }
        for language in AppLanguage.allCases where language != .system {
            language.write(defaults: temporary.defaults)
            #expect(temporary.defaults.stringArray(forKey: "AppleLanguages") == [language.rawValue])
            #expect(AppLanguage.read(defaults: temporary.defaults, domain: temporary.name) == language)
        }
        AppLanguage.system.write(defaults: temporary.defaults)
        #expect(temporary.defaults.persistentDomain(forName: temporary.name)?["AppleLanguages"] == nil)
        #expect(AppLanguage.read(defaults: temporary.defaults, domain: temporary.name) == .system)
    }

    @Test func ignoresGlobalFallbackAndInvalidValues() throws {
        let temporary = try TemporaryDefaults(prefix: "language-fallback.")
        defer { temporary.clean() }
        temporary.defaults.register(defaults: ["AppleLanguages": ["en"]])
        #expect(AppLanguage.read(defaults: temporary.defaults, domain: temporary.name) == .system)
        for value: Any in [["fr", "en"], [String](), "ja", 42] {
            temporary.defaults.set(value, forKey: "AppleLanguages")
            #expect(AppLanguage.read(defaults: temporary.defaults, domain: temporary.name) == .system)
        }
    }

    @Test func acceptsSystemSettingsRegionalCodes() throws {
        let temporary = try TemporaryDefaults(prefix: "language-regional.")
        defer { temporary.clean() }
        for (code, expected) in [
            ("zh-Hans-CN", AppLanguage.simplifiedChinese),
            ("zh-Hant-TW", .traditionalChinese), ("en-US", .english),
            ("ja-JP", .japanese), ("zh_CN", .simplifiedChinese),
            ("zh-TW", .traditionalChinese)
        ] {
            temporary.defaults.set([code], forKey: "AppleLanguages")
            #expect(AppLanguage.read(defaults: temporary.defaults, domain: temporary.name) == expected)
        }
        #expect(AppLanguage.language(for: "english") == .system)
    }

    @Test func relaunchWaitsForOldProcessAndPreservesArguments() async throws {
        let oldProcess = Process()
        oldProcess.executableURL = URL(filePath: "/bin/sleep")
        oldProcess.arguments = ["0.5"]
        try oldProcess.run()
        defer { if oldProcess.isRunning { oldProcess.terminate() } }
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appending(path: "a 'quoted' $literal file")
        let helper = AppRelaunch.waitingProcess(
            processID: oldProcess.processIdentifier, command: ["/usr/bin/touch", marker.path]
        )
        try helper.run()
        defer { if helper.isRunning { helper.terminate() } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        for _ in 0..<50 where helper.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!helper.isRunning)
        #expect(helper.terminationStatus == 0)
        #expect(!oldProcess.isRunning)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func relaunchHelperReportsLaunchFailure() async throws {
        let helper = AppRelaunch.waitingProcess(processID: Int32.max, command: ["/nonexistent/mulee-test"])
        try helper.run()
        for _ in 0..<50 where helper.isRunning {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!helper.isRunning)
        #expect(helper.terminationStatus != 0)
    }

    @Test func rendersGeneralSettingsInChineseAndEnglish() throws {
        let temporary = try TemporaryDefaults(prefix: "language-screenshots.")
        defer { temporary.clean() }
        let output = URL(filePath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "build")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for language in ["zh-Hans", "en"] {
            let content = GeneralSettingsTab()
                .environment(SettingsModel(defaults: temporary.defaults))
                .environment(AppModel(tasks: []))
                .environment(\.locale, Locale(identifier: language))
                .frame(width: 720, height: 1300)
                .background(Color(nsColor: .windowBackgroundColor))
            let hosting = NSHostingView(rootView: content)
            hosting.appearance = NSAppearance(named: .aqua)
            let bounds = NSRect(x: 0, y: 0, width: 720, height: 1300)
            let window = NSWindow(contentRect: bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            defer { window.close() }
            hosting.frame = bounds
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: output.appending(path: "lang-\(language).png"))
        }
    }
}

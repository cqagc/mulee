import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct VideoOutputOptionsTests {
    @Test func settingsDefaultsAndEveryOutputOptionPersistAndReachEngineConfiguration() throws {
        let storage = try TemporaryDefaults(prefix: "video-output-options.")
        defer { storage.clean() }
        let settings = SettingsModel(defaults: storage.defaults)
        let defaults = VideoEngineConfiguration.configuration(from: settings).output
        #expect(defaults.subtitleMode == .off)
        #expect(defaults.subtitleLanguages == YtDlpOutputOptions.preferredSubtitleLanguages())
        #expect(!defaults.autoCaptions && !defaults.sponsorBlockMark && !defaults.prefer60fps)
        #expect(defaults.audioFormat == .m4a && defaults.embedMetadata)
        #expect(defaults.codecPreference == .auto && defaults.filenamePreset == .title)

        settings.subtitleMode = .file
        settings.subtitleLanguages = ["en", "zh-Hans"]
        settings.autoCaptions = true
        settings.audioFormat = .mp3
        settings.embedMetadata = false
        settings.sponsorBlockMark = true
        settings.codecPreference = .av1
        settings.prefer60fps = true
        settings.filenamePreset = .uploaderTitle
        let restored = SettingsModel(defaults: storage.defaults)
        let output = VideoEngineConfiguration.configuration(from: restored).output
        #expect(output.subtitleMode == .file && output.autoCaptions)
        #expect(output.subtitleLanguages == ["en", "zh-Hans"])
        #expect(output.audioFormat == .mp3 && !output.embedMetadata)
        #expect(output.sponsorBlockMark && output.prefer60fps)
        #expect(output.codecPreference == .av1 && output.filenamePreset == .uploaderTitle)
        let arguments = output.arguments(quality: .compatible, site: .youtube)
        #expect(arguments.contains("--convert-subs") && arguments.contains("--sponsorblock-mark"))
        #expect(arguments.contains("vcodec:av1,fps:60"))
        #expect(!arguments.contains("--embed-metadata"))
    }

    @Test func invalidStoredEnumsFallBackToDefaults() throws {
        let storage = try TemporaryDefaults(prefix: "video-output-invalid.")
        defer { storage.clean() }
        for key in ["video.subtitleMode", "video.audioFormat", "video.codecPreference", "video.filenamePreset"] {
            storage.defaults.set("invalid", forKey: key)
        }
        let output = VideoEngineConfiguration.configuration(from: SettingsModel(defaults: storage.defaults)).output
        #expect(output.subtitleMode == .off && output.audioFormat == .m4a)
        #expect(output.codecPreference == .auto && output.filenamePreset == .title)
    }

    @Test func taskOptionsValidateSectionsAndIgnoreThemForMultipleSelections() throws {
        let link = try #require(LinkParser.parse("https://www.youtube.com/watch?v=Example0001").first)
        let item = NewTaskLinkModel(link: link)
        item.videoFormatID = "mulee:audio"
        item.videoSubtitleLanguages = ["en"]
        item.didSelectSubtitleLanguages = true
        #expect(item.videoOutputOptions.audioOnly == true)
        #expect(item.videoOutputOptions.subtitleLanguages == ["en"])
        #expect(item.videoOutputOptions.section == nil)
        item.videoSectionStart = "01:00"
        item.videoSectionEnd = "00:59"
        #expect(item.videoSectionError != nil && !item.canStart)
        item.videoSectionEnd = "02:00"
        #expect(item.videoSectionError == nil && item.canStart)
        #expect(item.videoOutputOptions.section?.argument == "*60-120")
        item.selectedVideoParts = [URL(string: "https://example.com/video/1")!, URL(string: "https://example.com/video/2")!]
        #expect(item.videoSectionError == nil)
        #expect(item.videoOutputOptions.section == nil)
    }

    @Test func coordinatorRetainsPerTaskOptionsInHistory() async throws {
        let model = AppModel(tasks: [])
        let video = FakeEngine(kind: .video)
        let coordinator = DownloadCoordinator(model: model, engines: [video])
        await coordinator.start(options: .init(downloadDirectory: FileManager.default.temporaryDirectory))
        let link = try #require(LinkParser.parse("https://www.youtube.com/watch?v=Example0001").first)
        let options = YtDlpTaskOptions(subtitleLanguages: [], audioOnly: true, section: try .init(start: "0", end: "10"))
        await coordinator.add(links: [link], autoExtract: false, videoOptions: [link: options])
        let task = try #require(model.tasks.first)
        #expect(task.videoOptions == options)
        let restored = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(task))
        #expect(restored.videoOptions == options)
        await coordinator.stop()
    }

    @Test func draftContextRetainsVideoOptionsWithoutCoordinator() throws {
        let link = try #require(LinkParser.parse("https://www.youtube.com/watch?v=Example0001").first)
        let options = YtDlpTaskOptions(subtitleLanguages: ["en"], audioOnly: true)
        var context = NewTaskContext()
        context.videoOptions = options
        let model = AppModel(tasks: [])
        model.addTasks(from: [link], autoExtract: false, contexts: [link: context])
        #expect(model.tasks.first?.videoOptions == options)
    }


    @Test func newTaskDraftPassesAudioLanguagesAndSectionToTask() throws {
        let draft = NewTaskModel(
            inputText: "https://www.youtube.com/watch?v=Example0001",
            saveDirectory: FileManager.default.temporaryDirectory
        )
        let item = try #require(draft.links.first)
        item.videoFormatID = "mulee:audio"
        item.videoSubtitleLanguages = ["en"]
        item.didSelectSubtitleLanguages = true
        item.videoSectionStart = "10"
        item.videoSectionEnd = "20"
        let model = AppModel(tasks: [])
        draft.createTasks(in: model)
        #expect(model.tasks.first?.videoOptions == YtDlpTaskOptions(
            subtitleLanguages: ["en"], audioOnly: true, section: try .init(start: "10", end: "20")
        ))
    }

}

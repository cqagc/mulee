import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite @MainActor struct HTTPTaskFeatureTests {
    @Test(arguments: ["meta4", "metalink"])
    func metalinkOpensAndDropsIntoTheDraftWithoutStartingDownloads(_ ext: String) throws {
        let file = URL(filePath: "/tmp/example [1-3] files.\(ext)")
        let request = try #require(OpenURLRequest.parse(file, detectPagePassword: false))
        #expect(request.links.count == 1)
        #expect(request.links.first?.kind == .http)
        #expect(NewTaskModel.droppedURLText(file) == file.path)
        let draft = NewTaskModel()
        #expect(draft.appendTorrentFiles([file]))
        #expect(draft.linkCount == 1)
        #expect(draft.links.first?.link.kind == .http)
        #expect(draft.links.first?.metadataError == nil)
        #expect(draft.parsedLinks.first?.original == file.absoluteString)
        let model = AppModel(tasks: [], preventsSleepWhileDownloading: false)
        let router = OpenURLRouter(model: model, settings: SettingsModel())
        #expect(router.open([file]))
        #expect(model.tasks.isEmpty)
        #expect(model.isShowingNewTask)
        #expect(!OpenURLRequest.isRemote(try #require(request.links.first)))
    }

    @Test func authenticationFlagIsOptionalForOldTaskHistory() throws {
        let link = try #require(LinkParser.parse("https://example.org/example.bin").first)
        var task = DownloadTask(link: link, autoExtract: false)
        #expect(task.hasHTTPCredentials == nil)
        task.hasHTTPCredentials = true
        let decoded = try JSONDecoder().decode(DownloadTask.self, from: JSONEncoder().encode(task))
        #expect(decoded.hasHTTPCredentials == true)
    }

    @Test func onlyActiveHTTPVideosCanStartBuffering() throws {
        let link = try #require(LinkParser.parse("https://example.org/example.mp4").first)
        var task = DownloadTask(link: link, autoExtract: false)
        task.engineTaskID = "example"
        task.status = .downloading
        task.savePath = URL(filePath: "/tmp/.mulee-incomplete/example/example.mp4")
        #expect(StreamingPlayback.canPlay(task))
        task.status = .failed
        #expect(!StreamingPlayback.canPlay(task))
        task.status = .downloading
        task.fileMissing = true
        #expect(!StreamingPlayback.canPlay(task))
        task.fileMissing = false
        task.savePath = URL(filePath: "/tmp/.mulee-incomplete/example/example.zip")
        #expect(!StreamingPlayback.canPlay(task))
    }
}

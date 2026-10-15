import Foundation
import MuleeCore
import Testing
@testable import Mulee

@MainActor
@Suite struct TaskPostDownloadPresentationTests {
    @Test func videosHideExtractionSettingsAndEmptyCard() throws {
        var task = try #require(MockData.tasks.first { $0.kind == .video })
        task.postDownload = PostDownloadInfo(autoExtract: true)
        let enabled = TaskPresentation(task: task)

        #expect(enabled.extractionSetting == nil)
        #expect(!enabled.showsPostDownload)

        task.postDownload.autoExtract = false
        let disabled = TaskPresentation(task: task)
        #expect(disabled.extractionSetting == nil)
        #expect(!disabled.showsPostDownload)
    }

    @Test func nonVideoTasksKeepSettings() throws {
        for kind in [TaskKind.http, .bittorrent, .ed2k] {
            var task = try #require(MockData.tasks.first { $0.kind == kind })
            task.postDownload = PostDownloadInfo(autoExtract: true)
            let enabled = TaskPresentation(task: task)
            #expect(enabled.extractionSetting == String(localized: "开"))
            #expect(enabled.filenameEncoding == String(localized: "自动检测"))
            #expect(enabled.showsPostDownload)

            task.postDownload.autoExtract = false
            let disabled = TaskPresentation(task: task)
            #expect(disabled.extractionSetting == String(localized: "关"))
            #expect(disabled.showsPostDownload)
        }
    }

    @Test func videoCardRetainsOtherPostDownloadInformation() throws {
        var task = try #require(MockData.tasks.first { $0.kind == .video })
        task.postDownload = PostDownloadInfo(autoExtract: true)
        task.postDownload.extractionWarnings = ["warning"]
        let presentation = TaskPresentation(task: task)

        #expect(presentation.extractionSetting == nil)
        #expect(presentation.showsPostDownload)
    }
}

import Foundation
import MuleeCore
import Testing
@testable import Mulee

@MainActor
@Suite struct NewTaskFooterHintTests {
    @Test func hintsOnlyMentionSitesInDraftWithoutLogin() {
        let draft = NewTaskModel(inputText: "https://www.bilibili.com/video/BV1xx\nhttps://youtu.be/example")

        #expect(draft.videoLoginHintSites(loggedInSites: []) == [.bilibili, .youtube])
        #expect(draft.videoLoginHintSites(loggedInSites: [.bilibili]) == [.youtube])
        #expect(draft.videoLoginHintSites(loggedInSites: [.youtube]) == [.bilibili])
        #expect(draft.videoLoginHintSites(loggedInSites: [.bilibili, .youtube]).isEmpty)

        draft.inputText = "https://b23.tv/example"

        #expect(draft.videoLoginHintSites(loggedInSites: [.youtube]) == [.bilibili])
        #expect(draft.videoLoginHintSites(loggedInSites: [.bilibili]).isEmpty)
    }

    @Test func duplicateSitesHaveOneHintAndOtherLinksHaveNone() {
        let draft = NewTaskModel(inputText: "https://youtu.be/one\nhttps://www.youtube.com/watch?v=two")

        #expect(draft.videoLoginHintSites(loggedInSites: []) == [.youtube])

        draft.inputText = "https://example.com/archive.zip"
        #expect(draft.videoLoginHintSites(loggedInSites: []).isEmpty)

        let otherVideo = ParsedLink.video(
            url: URL(string: "https://example.com/video")!, site: .other, original: "other"
        )
        let otherDraft = NewTaskModel(parser: { _ in [otherVideo] })
        #expect(otherDraft.videoLoginHintSites(loggedInSites: []).isEmpty)
        #expect(!otherDraft.showsAutoExtract)

        draft.inputText = ""
        #expect(draft.videoLoginHintSites(loggedInSites: []).isEmpty)
    }

    @Test func extractionToggleOnlyHidesForNonemptyVideoOnlyDraft() {
        let draft = NewTaskModel()
        #expect(draft.showsAutoExtract)

        draft.inputText = "https://www.bilibili.com/video/BV1xx\nhttps://youtu.be/example"
        #expect(!draft.showsAutoExtract)

        draft.inputText += "\nhttps://example.com/archive.zip"
        #expect(draft.showsAutoExtract)
        #expect(draft.autoExtract)

        draft.inputText = "https://example.com/archive.zip"
        #expect(draft.showsAutoExtract)
    }
}

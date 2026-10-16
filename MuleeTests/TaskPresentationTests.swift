import Foundation
import MuleeCore
import Testing
@testable import Mulee

@MainActor
@Suite struct TaskPresentationTests {
    private let now = Date(timeIntervalSince1970: 1_792_022_400)
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    @Test(arguments: [TaskStatus.paused, .queued])
    func schedulePauseExplainsWhyItIsWaiting(status: TaskStatus) {
        var task = MockData.tasks[0]
        task.status = status
        task.pauseReason = .schedule
        let presentation = TaskPresentation(task: task)
        #expect(presentation.statusTitle.contains("计划"))
        #expect(presentation.statusSubtitle != "等待空位")
        task.pauseReason = .diskSpace
        task.status = .paused
        #expect(TaskPresentation(task: task).statusTitle == "因磁盘空间不足已暂停")
    }

    @Test func schedulePauseUsesTheNextStartAcrossMidnight() throws {
        var task = MockData.tasks[0]
        task.status = .paused
        task.pauseReason = .schedule
        let schedule = TransferScheduleController.Configuration(startTime: "22:00", endTime: "07:00", weekdays: [6])
        let now = try #require(ISO8601DateFormatter().date(from: "2026-10-17T08:00:00Z"))
        let presentation = TaskPresentation(task: task, now: now, calendar: calendar, schedule: schedule)
        #expect(presentation.statusTitle == "按计划暂停，22:00 自动继续")
    }

    @Test func httpMatchesPrototype() throws {
        let task = try #require(MockData.tasks.first { $0.kind == .http && $0.status == .downloading })
        let presentation = TaskPresentation(task: task)

        #expect(presentation.typeLabel == "HTTP")
        #expect(presentation.metadata == "6.1 GB · 8 线程")
        #expect(presentation.progressText == "62% · 3.8 / 6.1 GB")
        #expect(presentation.statusTitle == "11.2 MB/s")
        #expect(presentation.statusSubtitle == "剩 3 分钟")
        #expect(presentation.progressStyle == .accent)
    }

    @Test func torrentDownloadAndSeedingMatchPrototype() throws {
        let download = try #require(MockData.tasks.first { $0.kind == .bittorrent && $0.status == .downloading })
        let seed = try #require(MockData.tasks.first { $0.status == .seeding })
        let downloading = TaskPresentation(task: download)
        let seeding = TaskPresentation(task: seed)

        #expect(downloading.typeLabel == "BT")
        #expect(downloading.metadata == "12 个文件，已选 3 个 · 46 个节点")
        #expect(seeding.metadata == "3.9 GB · 分享率 0.64 / 1.00")
        #expect(seeding.progress == 0.64)
        #expect(seeding.progressText == "做种 64% · 到 1:1 后降速")
        #expect(seeding.statusTitle == "↑ 380 KB/s")
        #expect(seeding.statusSubtitle == "做种中")
        #expect(seeding.progressStyle == .success)
    }

    @Test func longTailWithSourcesMatchesPrototype() throws {
        var task = MockData.longTailTask
        var info = try #require(TaskPresentation(task: task).longTail)
        info.waitingSince = now.addingTimeInterval(-12 * 86_400)
        info.lastCompleteSourceSeen = now.addingTimeInterval(-3 * 86_400)
        task.detail = .ed2k(hash: "9F3A", longTail: info)
        let presentation = TaskPresentation(task: task, now: now, calendar: calendar)

        #expect(presentation.typeLabel == "ED2K")
        #expect(presentation.metadata == "612 MB · 2 个来源，排队第 14 位")
        #expect(presentation.progressText == "41% · 251 / 612 MB")
        #expect(presentation.inspectorProgressText == "41% · 已收到 251 MB，剩余 361 MB")
        #expect(presentation.statusTitle == "等待来源")
        #expect(presentation.statusSubtitle == "已挂 12 天")
        #expect(presentation.isStatusEmphasized)
        #expect(presentation.progressStyle == .waiting)
        #expect(presentation.longTailStatus == "排队中，第 14 位")
        #expect(presentation.sourceSummary == "2 个（1 个完整）")
        #expect(presentation.lastCompleteSource == "3 天前")
        #expect(presentation.waitingDuration == "12 天")
        #expect(presentation.transferDuration == "6 小时 12 分")
        #expect(presentation.extractionSetting == "开")
        #expect(presentation.filenameEncoding == "自动检测（Big5）")
        #expect(presentation.hash == "ED2K 9F3A")
    }

    @Test func noSourcesUsesStableDate() throws {
        var task = try #require(MockData.tasks.first {
            if case .ed2k(_, let info) = $0.detail { info.sourceCount == 0 } else { false }
        })
        var info = try #require(TaskPresentation(task: task).longTail)
        info.lastCompleteSourceSeen = calendar.date(from: DateComponents(year: 2026, month: 8, day: 2))
        info.waitingSince = now.addingTimeInterval(-31 * 86_400)
        task.detail = .ed2k(hash: "TEST", longTail: info)
        let presentation = TaskPresentation(task: task, now: now, calendar: calendar)

        #expect(presentation.metadata == "702 MB · 暂无来源，完整源最后出现于 8 月 2 日")
        #expect(presentation.progressText == "3% · 21 / 702 MB")
        #expect(presentation.statusSubtitle == "已挂 31 天")

        info.lastCompleteSourceSeen = nil
        task.detail = .ed2k(hash: "TEST", longTail: info)
        let unseen = TaskPresentation(task: task, now: now, calendar: calendar)
        #expect(unseen.metadata == "702 MB · 暂无来源，尚未见到完整源")
        #expect(unseen.lastCompleteSource == "尚未见到")
    }

    @Test func mergeAndExtractionMatchPrototype() throws {
        let video = try #require(MockData.tasks.first { $0.status == .postProcessing })
        let archive = try #require(MockData.tasks.first { $0.status == .extracting })
        let merging = TaskPresentation(task: video)
        let extracting = TaskPresentation(task: archive)

        #expect(merging.typeLabel == "视频")
        #expect(merging.metadata == "Bilibili · 1080P 高码率 · 弹幕转 ASS")
        #expect(merging.progressText == "96% · 合并音视频")
        #expect(merging.statusTitle == "处理中")
        #expect(merging.statusSubtitle == "即将完成")
        #expect(extracting.metadata == "1.3 GB · 命中解压规则「example-share.com」")
        #expect(extracting.progress == 0.7)
        #expect(extracting.progressText == "解压中 · 70%")
        #expect(extracting.statusTitle == "解压中")
        #expect(extracting.statusSubtitle == "已修复文件名编码")
        #expect(extracting.progressStyle == .success)
    }

    @Test func completionAndPauseMatchPrototype() throws {
        var task = try #require(MockData.tasks.first { $0.status == .completed })
        task.completedAt = calendar.date(from: DateComponents(year: 2026, month: 10, day: 15, hour: 10, minute: 42))
        let completed = TaskPresentation(task: task, now: now, calendar: calendar)

        #expect(completed.progressText == "2.1 GB")
        #expect(completed.statusTitle == "已完成")
        #expect(completed.statusSubtitle == "10:42")
        #expect(completed.progressStyle == .completed)
        #expect(completed.progress == 1)
        #expect(!completed.canPauseOrResume)

        task.status = .paused
        let paused = TaskPresentation(task: task)
        #expect(paused.statusTitle == "已暂停")
        #expect(paused.statusSubtitle.isEmpty)
        #expect(paused.pauseTitle == "继续")
        #expect(paused.canPauseOrResume)
    }

    @Test func missingSizeAndProgressStayValid() {
        var task = MockData.longTailTask
        task.totalBytes = nil
        let unknown = TaskPresentation(task: task)
        #expect(unknown.size == "大小未知")
        #expect(unknown.progress == 0)
        #expect(unknown.progressText == "0% · 已收到 251 MB")

        task.status = .extracting
        task.postDownload.extractProgress = 1.2
        #expect(TaskPresentation(task: task).progress == 1)
        task.postDownload.extractProgress = -0.2
        #expect(TaskPresentation(task: task).progress == 0)
    }

    @Test func zeroAndSubminuteRatesUseNumericChineseCopy() throws {
        var task = try #require(MockData.tasks.first { $0.kind == .http })
        task.downloadRate = 0
        task.estimatedTimeRemaining = .seconds(30)
        let presentation = TaskPresentation(task: task)

        #expect(presentation.statusTitle == "0 KB/s")
        #expect(presentation.statusSubtitle == "剩 30 秒")
    }
}

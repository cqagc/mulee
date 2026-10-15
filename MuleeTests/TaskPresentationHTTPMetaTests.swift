import MuleeCore
import Testing
@testable import Mulee

/// HTTP 任务的元信息行：线程数只在下载中显示。
@Suite struct TaskPresentationHTTPMetaTests {
    private func httpTask(status: TaskStatus, connections: Int) -> DownloadTask {
        DownloadTask(
            name: "file.zip",
            fileExtension: "zip",
            kind: .http,
            status: status,
            totalBytes: 50_000_000,
            receivedBytes: 25_000_000,
            detail: .http(connections: connections),
            postDownload: PostDownloadInfo(autoExtract: false),
            sourceLink: "https://example.com/file.zip"
        )
    }

    @Test func downloadingShowsConnections() {
        #expect(TaskPresentation(task: httpTask(status: .downloading, connections: 3)).metadata.contains("3 线程"))
    }

    @Test(arguments: [TaskStatus.completed, .paused, .queued, .failed])
    func otherStatesShowSizeOnly(_ status: TaskStatus) {
        #expect(!TaskPresentation(task: httpTask(status: status, connections: 0)).metadata.contains("线程"))
    }
}

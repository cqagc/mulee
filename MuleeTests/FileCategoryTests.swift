import MuleeCore
import Testing
@testable import Mulee

@MainActor
@Suite struct FileCategoryTests {
    @Test(arguments: [
        ("pdf", FileCategory.pdf), ("PDF", .pdf), (".PnG", .image),
        ("doc", .document), ("docx", .document), ("pages", .document), ("rtf", .document), ("odt", .document),
        ("xls", .spreadsheet), ("xlsx", .spreadsheet), ("numbers", .spreadsheet), ("csv", .spreadsheet), ("ods", .spreadsheet),
        ("ppt", .presentation), ("pptx", .presentation), ("key", .presentation), ("odp", .presentation),
        ("epub", .ebook), ("mobi", .ebook), ("azw3", .ebook), ("djvu", .ebook),
        ("heic", .image), ("webp", .image), ("raw", .image), ("jpeg", .image), ("avif", .image), ("dng", .image),
        ("mkv", .video), ("webm", .video), ("flv", .video), ("rmvb", .video), ("ts", .video), ("mov", .video),
        ("flac", .audio), ("ape", .audio), ("m4a", .audio), ("opus", .audio), ("wav", .audio),
        ("zip", .archive), ("rar", .archive), ("7z", .archive), ("tar", .archive), ("gz", .archive),
        ("bz2", .archive), ("xz", .archive), ("zst", .archive), ("001", .archive), ("z01", .archive),
        ("iso", .diskImage), ("img", .diskImage), ("bin", .diskImage), ("cue", .diskImage),
        ("mdf", .diskImage), ("mds", .diskImage), ("nrg", .diskImage), ("ccd", .diskImage),
        ("dmg", .installer), ("pkg", .installer), ("exe", .installer), ("msi", .installer), ("apk", .installer), ("app", .installer),
        ("swift", .code), ("txt", .code), ("md", .code), ("json", .code), ("py", .code), ("tsx", .code),
        ("unknown", .other), ("", .other), (" ", .other)
    ])
    func extensionClassification(_ suffix: String, _ expected: FileCategory) {
        let category = FileCategory(filenameExtension: suffix)
        #expect(category == expected)
    }

    @Test(arguments: [
        ("资料.001", FileCategory.archive), ("资料.part1.rar", .archive), ("资料.PART12.RAR", .archive),
        ("资料.z01", .archive), ("资料.r00", .archive), ("资料.tar.gz", .archive),
        ("资料.7z.002", .archive), ("报告.DOCX", .document), ("未知.xyz", .other), ("无扩展名", .other)
    ])
    func filenameClassification(_ name: String, _ expected: FileCategory) {
        let category = FileCategory(filename: name)
        #expect(category == expected)
    }

    @Test func taskInference() {
        var task = MockData.longTailTask
        task.fileExtension = "PDF"
        #expect(FileCategory(task: task) == .pdf)

        task.kind = .bittorrent
        task.detail = .bittorrent(fileCount: 12, selectedFileCount: 3, peerCount: 0, shareRatio: 0)
        #expect(FileCategory(task: task) == .folder)

        task.detail = .bittorrent(fileCount: 1, selectedFileCount: 1, peerCount: 0, shareRatio: 0)
        #expect(FileCategory(task: task) == .pdf)
        task.fileExtension = nil
        #expect(FileCategory(task: task) == .folder)

        task.kind = .video
        task.detail = .http(connections: 1)
        #expect(FileCategory(task: task) == .video)
        task.fileExtension = "webm"
        #expect(FileCategory(task: task) == .video)

        task.kind = .http
        task.fileExtension = nil
        task.name = "报告.pages"
        #expect(FileCategory(task: task) == .document)
        task.name = "下载"
        #expect(FileCategory(task: task) == .other)
    }

    @Test(arguments: FileCategory.allCases)
    func categoryAvoidsAttentionHue(_ category: FileCategory) {
        if let hue = category.hue {
            #expect(!(60...95).contains(hue))
        }
    }
}

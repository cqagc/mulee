import Foundation
import MuleeCore

/// 文件的视觉类别；协议类型与文件类别相互独立。
enum FileCategory: String, CaseIterable, Sendable {
    case pdf
    case presentation
    case ebook
    case spreadsheet
    case image
    case archive
    case folder
    case document
    case diskImage
    case video
    case audio
    case code
    case installer
    case other

    init(filenameExtension: String) {
        let suffix = filenameExtension.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".").last.map(String.init) ?? ""
        switch suffix {
        case "pdf": self = .pdf
        case "ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx", "key", "odp": self = .presentation
        case "epub", "mobi", "azw", "azw3", "azw4", "djvu", "djv", "fb2", "ibooks": self = .ebook
        case "xls", "xlsx", "xlsm", "xlsb", "numbers", "csv", "tsv", "ods": self = .spreadsheet
        case "jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "bmp", "tif", "tiff",
             "svg", "ico", "icns", "raw", "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "psd": self = .image
        case "zip", "rar", "7z", "tar", "gz", "gzip", "tgz", "bz2", "tbz", "tbz2", "xz", "txz",
             "zst", "zstd", "lz", "lzma", "lzh", "cab", "sit", "sitx": self = .archive
        case "doc", "docx", "docm", "pages", "rtf", "rtfd", "odt": self = .document
        case "iso", "img", "bin", "cue", "mdf", "mds", "nrg", "ccd", "vhd", "vhdx", "vmdk": self = .diskImage
        case "mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "rm", "rmvb", "ts", "mts", "m2ts",
             "mpeg", "mpg", "m2v", "wmv", "3gp", "ogv", "vob": self = .video
        case "mp3", "flac", "ape", "m4a", "aac", "opus", "ogg", "oga", "wav", "aif", "aiff",
             "alac", "wma", "amr", "mid", "midi", "dsf", "dff": self = .audio
        case "dmg", "pkg", "mpkg", "exe", "msi", "msix", "apk", "aab", "app", "deb", "rpm": self = .installer
        case "txt", "text", "md", "markdown", "log", "json", "jsonl", "xml", "yaml", "yml", "toml",
             "ini", "conf", "cfg", "html", "htm", "css", "scss", "sass", "js", "jsx",
             "mjs", "cjs", "tsx", "vue", "svelte", "swift", "m", "mm", "h", "hpp", "c", "cpp",
             "cc", "rs", "go", "py", "rb", "java", "kt", "kts", "dart", "php", "sh", "bash",
             "zsh", "fish", "ps1", "bat", "sql", "r", "ipynb", "srt", "ass", "vtt": self = .code
        default:
            let numberedVolume = suffix.count == 3 && suffix.allSatisfy(\.isNumber)
            let zipOrRARVolume = suffix.count == 3
                && (suffix.first == "z" || suffix.first == "r")
                && suffix.dropFirst().allSatisfy(\.isNumber)
            self = numberedVolume || zipOrRARVolume ? .archive : .other
        }
    }

    init(filename: String) {
        self.init(filenameExtension: (filename as NSString).pathExtension)
    }

    init(task: DownloadTask) {
        if case .bittorrent(let count, _, _, _) = task.detail, count > 1 {
            self = .folder
        } else if let suffix = task.fileExtension, !suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.init(filenameExtension: suffix)
        } else if task.kind == .bittorrent {
            self = .folder
        } else if task.kind == .video {
            self = .video
        } else {
            self.init(filename: task.name)
        }
    }

    var title: String {
        switch self {
        case .pdf: "PDF"
        case .presentation: String(localized: "演示文稿")
        case .ebook: String(localized: "电子书")
        case .spreadsheet: String(localized: "表格")
        case .image: String(localized: "图片")
        case .archive: String(localized: "压缩包")
        case .folder: String(localized: "文件夹")
        case .document: String(localized: "文字文档")
        case .diskImage: String(localized: "光盘镜像")
        case .video: String(localized: "视频")
        case .audio: String(localized: "音频")
        case .code: String(localized: "文本与代码")
        case .installer: String(localized: "安装包")
        case .other: String(localized: "其他")
        }
    }

    var hue: Double? {
        switch self {
        case .pdf: 25
        case .presentation: 50
        case .ebook: 105
        case .spreadsheet: 150
        case .image: 175
        case .archive: 200
        case .folder: 225
        case .document: 250
        case .diskImage: 275
        case .video: 300
        case .audio: 340
        case .code, .installer, .other: nil
        }
    }

    var symbol: MuleeSymbol? {
        switch self {
        case .pdf: nil
        case .presentation: .filePresentation
        case .ebook: .fileEbook
        case .spreadsheet: .fileSpreadsheet
        case .image: .fileImage
        case .archive: .fileArchive
        case .folder: .fileFolder
        case .document: .fileDocument
        case .diskImage: .fileDiskImage
        case .video: .resume
        case .audio: .fileAudio
        case .code: .ruleFilenameRegex
        case .installer: .fileInstaller
        case .other: .fileOther
        }
    }

    var representativeExtension: String {
        switch self {
        case .pdf: "pdf"
        case .presentation: "pptx"
        case .ebook: "epub"
        case .spreadsheet: "xlsx"
        case .image: "heic"
        case .archive: "zip"
        case .folder: ""
        case .document: "docx"
        case .diskImage: "iso"
        case .video: "mkv"
        case .audio: "flac"
        case .code: "swift"
        case .installer: "dmg"
        case .other: "dat"
        }
    }

    func badgeText(filenameExtension: String?, size: CGFloat) -> String? {
        guard size >= 48, [.video, .audio, .archive, .diskImage, .image, .ebook].contains(self),
              let suffix = filenameExtension?.trimmingCharacters(in: .whitespacesAndNewlines),
              !suffix.isEmpty else { return nil }
        return String(suffix.uppercased().prefix(4))
    }
}

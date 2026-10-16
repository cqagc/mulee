import Foundation

public enum DownloadCategory: String, CaseIterable, Sendable, Codable {
    case video, audio, archive, document, program, image

    public var folderName: String {
        switch self {
        case .video: String(localized: "视频", bundle: .module)
        case .audio: String(localized: "音频", bundle: .module)
        case .archive: String(localized: "压缩包", bundle: .module)
        case .document: String(localized: "文档", bundle: .module)
        case .program: String(localized: "程序", bundle: .module)
        case .image: String(localized: "镜像", bundle: .module)
        }
    }

    public static func classify(extension value: String?) -> Self? {
        let ext = (value ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return switch ext {
        case "mp4", "mkv", "mov", "avi", "webm", "m4v", "ts", "flv": .video
        case "mp3", "m4a", "flac", "wav", "aac", "ogg", "opus", "aiff": .audio
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz", "zst": .archive
        case "pdf", "txt", "md", "rtf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "epub", "csv": .document
        case "app", "pkg", "exe", "msi", "deb", "rpm", "apk": .program
        case "iso", "img", "dmg", "vhd", "vhdx": .image
        default: nil
        }
    }
}

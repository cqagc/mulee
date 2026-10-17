import Foundation

nonisolated enum TorrentPreviewError: Error, Equatable {
    case unreadable
    case tooLarge
}

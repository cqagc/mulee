import Foundation

nonisolated struct TorrentPreviewRow: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let depth: Int
    let size: Int64?
}

import Foundation

struct TorrentdPending<Value: Sendable>: Sendable {
    let continuation: CheckedContinuation<Value, any Error>
    let timeout: Task<Void, Never>
}

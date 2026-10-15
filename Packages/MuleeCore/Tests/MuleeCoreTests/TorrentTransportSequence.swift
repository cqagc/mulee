import Synchronization
@testable import MuleeCore

final class TorrentTransportSequence: Sendable {
    private let remaining: Mutex<[TorrentFakeTransport]>
    private let count = Mutex(0)

    init(_ transports: [TorrentFakeTransport]) { remaining = Mutex(transports) }

    func make() -> any TorrentdTransport {
        count.withLock { $0 += 1 }
        return remaining.withLock { transports in
            if transports.isEmpty { return TorrentFakeTransport(sendsReady: false) }
            return transports.removeFirst()
        }
    }

    var created: Int { count.withLock { $0 } }
}

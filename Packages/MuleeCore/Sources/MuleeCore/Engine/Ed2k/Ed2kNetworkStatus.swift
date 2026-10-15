import Foundation

/// 电驴网络连接信息，复用现有模型中的 ID / Kad 枚举。
public struct Ed2kNetworkStatus: Sendable, Hashable {
    public var serverConnected: Bool
    public var ed2kID: NetworkStatus.Ed2kID
    public var kad: NetworkStatus.KadState
    public var serverName: String?

    init(tag: ECTag) throws {
        guard let flags = tag.number else { throw ECError.malformed(String(localized: "缺少网络连接状态", bundle: .module)) }
        serverConnected = flags & 1 != 0
        if serverConnected {
            guard let id = tag.tag(ECCode.Tag.ed2kID)?.number else { throw ECError.malformed(String(localized: "缺少电驴 ID", bundle: .module)) }
            ed2kID = id < 0x1000000 ? .low : .high
        } else {
            ed2kID = .disconnected
        }
        kad = flags & 4 == 0 ? .disconnected : flags & 8 != 0 ? .firewalled : .open
        serverName = serverConnected ? tag.tag(ECCode.Tag.server)?.tag(ECCode.Tag.serverName)?.string : nil
    }
}

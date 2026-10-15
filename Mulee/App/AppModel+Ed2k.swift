import MuleeCore
import OSLog

extension AppModel {
    /// 只更新电驴字段，BT、出口与端口映射由各自的监测器维护。
    func updateEd2kNetworkStatus(id: NetworkStatus.Ed2kID, kad: NetworkStatus.KadState) {
        if networkStatus.ed2kID != id || networkStatus.kad != kad {
            Logger(subsystem: "com.cqagc.mulee", category: "Ed2k")
                .notice("电驴网络状态写入 AppModel：ed2k=\(id.rawValue, privacy: .public)，kad=\(kad.rawValue, privacy: .public)")
        }
        networkStatus.ed2kID = id
        networkStatus.kad = kad
    }
}

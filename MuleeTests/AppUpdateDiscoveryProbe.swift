import Foundation
import Sparkle

/// 只执行 Sparkle 的 information 检查，不下载或安装更新。
@MainActor
final class AppUpdateDiscoveryProbe: NSObject, SPUUpdaterDelegate {
    private(set) var parsedItems = 0
    private(set) var version: String?
    private(set) var error: (any Error)?
    private(set) var finished = false

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        parsedItems = appcast.items.count
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        version = item.versionString
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
                 error: (any Error)?) {
        self.error = error
        finished = true
    }
}

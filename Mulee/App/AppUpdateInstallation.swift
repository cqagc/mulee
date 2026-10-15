import Foundation

/// 更新安装前的确认与保存步骤；测试可注入确认结果和引擎退出操作。
@MainActor
final class AppUpdateInstallation {
    var hasActiveTransfers: () -> Bool = { false }
    var confirm: () -> Bool = { true }
    var prepare: () async -> Bool = { true }
    private(set) var isPrepared = false
    private var isConfirmed = false
    private var preparationTask: Task<Bool, Never>?

    func mayInstall() -> Bool {
        if isPrepared || isConfirmed { return true }
        guard !hasActiveTransfers() || confirm() else { return false }
        isConfirmed = true
        return true
    }

    func prepareForInstallation() async -> Bool {
        guard mayInstall() else { return false }
        if isPrepared { return true }
        if let preparationTask { return await preparationTask.value }
        let prepare = prepare
        let task = Task { await prepare() }
        preparationTask = task
        isPrepared = await task.value
        preparationTask = nil
        if !isPrepared { isConfirmed = false }
        return isPrepared
    }

    func reset() {
        isConfirmed = false
        isPrepared = false
    }
}

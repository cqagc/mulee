import AppKit

/// 只保存打开事件，不创建模型、路由器或后台服务。
@MainActor
final class SingleInstanceHandoff {
    private let session: SingleInstanceSession
    private let send: @MainActor ([URL], pid_t) async -> Void
    private let activate: @MainActor (pid_t) -> Void
    private let terminate: @MainActor () -> Void
    private var urls: [URL] = []
    private var seen: Set<URL> = []
    private var isFinished = false

    init(
        session: SingleInstanceSession,
        send: @escaping @MainActor ([URL], pid_t) async -> Void,
        activate: @escaping @MainActor (pid_t) -> Void,
        terminate: @escaping @MainActor () -> Void
    ) {
        self.session = session
        self.send = send
        self.activate = activate
        self.terminate = terminate
    }

    func receive(_ incoming: [URL]) {
        guard !isFinished else { return }
        for url in incoming where seen.insert(url).inserted { urls.append(url) }
    }

    func finish() async {
        guard !isFinished else { return }
        // 先关入口；同一路径的副本被 Launch Services 回送事件时绝不再转交。
        isFinished = true
        if let pid = session.ownerProcessID {
            if !urls.isEmpty { await send(urls, pid) }
            activate(pid)
        }
        terminate()
    }

    private static func runningOwner(_ pid: pid_t) -> NSRunningApplication? {
        guard pid != ProcessInfo.processInfo.processIdentifier, let bundleID = Bundle.main.bundleIdentifier else { return nil }
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            $0.processIdentifier == pid && !$0.isTerminated
        }
    }

    static func send(_ urls: [URL], to pid: pid_t) async {
        guard let owner = runningOwner(pid), let bundleURL = owner.bundleURL else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = false
        configuration.allowsRunningApplicationSubstitution = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        do {
            let recipient = try await NSWorkspace.shared.open(urls, withApplicationAt: bundleURL, configuration: configuration)
            if recipient.processIdentifier == pid { return }
        } catch {
            // Launch Services 无法唯一定位同路径实例时，下面按持锁 PID 投递。
        }
        // GURL 由 AppKit 送进同一个 application(_:open:) 入口，不绕过 router 校验。
        // 只在 Workspace 没有选中持锁进程时使用，避免正常转交重复投递。
        guard runningOwner(pid) != nil else { return }
        for url in urls {
            let event = NSAppleEventDescriptor(
                eventClass: AEEventClass(kInternetEventClass), eventID: AEEventID(kAEGetURL),
                targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID)
            )
            event.setParam(NSAppleEventDescriptor(string: url.absoluteString), forKeyword: AEKeyword(keyDirectObject))
            _ = try? event.sendEvent(options: [.noReply, .neverInteract, .dontRecord], timeout: 1)
        }
    }

    static func activate(_ pid: pid_t) {
        runningOwner(pid)?.activate()
    }
}

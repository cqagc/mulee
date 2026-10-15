import AppKit

/// 系统服务只打开待确认的草稿，绝不直接创建下载任务。
final class DownloadServicesProvider: NSObject {
    private let router: OpenURLRouter?

    init(router: OpenURLRouter?) {
        self.router = router
    }

    @objc(downloadWithMulee:userData:error:)
    func downloadWithMulee(
        _ pasteboard: NSPasteboard, userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        guard let text = pasteboard.string(forType: .string) ?? pasteboard.string(forType: .URL),
              router?.openSelectedText(text) == true else {
            error.pointee = String(localized: "所选文本中没有可下载的链接。") as NSString
            return
        }
    }
}

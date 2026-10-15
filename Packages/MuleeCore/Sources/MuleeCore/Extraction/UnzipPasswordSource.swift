import Foundation

/// 只携带标识，不携带密码；可安全用于界面显示和结果记录。
public enum UnzipPasswordSource: Sendable, Equatable {
    case keychainItem(String)
    case passwordBook
}

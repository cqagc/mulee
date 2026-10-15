import Foundation

/// 从打包后的 Info.plist 读取发布版本和构建号。
enum AboutVersion {
    static func display(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "—"
        let build = info["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }
}

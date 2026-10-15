import Foundation

/// 页面文字和压缩包注释使用同一套识别规则；结果只在内存中参与解压。
public enum PasswordTextParser {
    public static func password(in text: String) -> String? {
        guard let match = text.firstMatch(of: #/(?i)(?:解压密码|密码|password)\s*[:：]\s*([^\s，。；;]+)/#) else { return nil }
        return String(match.1)
    }
}

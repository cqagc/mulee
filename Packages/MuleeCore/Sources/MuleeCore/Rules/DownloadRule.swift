import Foundation

/// 空条件表示不限；同一条规则的条件同时满足，列表中第一条命中生效。
public struct DownloadRule: Identifiable, Sendable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var sourceSite: String
    public var extensions: [String]
    public var taskKind: TaskKind?
    public var subdirectory: String
    public var userAgent: String?
    public var httpThreads: Int?
    public var speedLimitBytes: Int64?

    public init(
        id: UUID = UUID(), name: String, sourceSite: String = "", extensions: [String] = [],
        taskKind: TaskKind? = nil, subdirectory: String = "", userAgent: String? = nil,
        httpThreads: Int? = nil, speedLimitBytes: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.sourceSite = sourceSite
        self.extensions = extensions
        self.taskKind = taskKind
        self.subdirectory = subdirectory
        self.userAgent = userAgent
        self.httpThreads = httpThreads
        self.speedLimitBytes = speedLimitBytes
    }

    public func matches(sourceURL: URL?, filename: String, kind: TaskKind) -> Bool {
        if let taskKind, taskKind != kind { return false }
        if !sourceSite.isEmpty, !RuleMatcher.domain(sourceURL?.host, matches: sourceSite) { return false }
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return extensions.isEmpty || extensions.contains {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".")) == ext
        }
    }

    public static func firstMatch(
        in rules: [Self], context: DownloadRequestContext, downloadURL: URL?, filename: String, kind: TaskKind
    ) -> Self? {
        rules.first { $0.matches(sourceURL: context.referer?.host == nil ? downloadURL : context.referer, filename: filename, kind: kind) }
    }

    /// 只允许保存目录下的相对路径，设置导入也不能逃逸到其他目录。
    public func saveDirectory(under root: URL) -> URL? {
        guard !subdirectory.isEmpty, !subdirectory.hasPrefix("/"), !subdirectory.contains("\\"),
              !subdirectory.split(separator: "/").contains(".."), !subdirectory.utf8.contains(0) else { return nil }
        return root.appendingPathComponent(subdirectory, isDirectory: true)
    }
}

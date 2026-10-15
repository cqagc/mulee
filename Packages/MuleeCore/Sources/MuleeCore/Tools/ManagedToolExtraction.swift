/// 安装时的解包方式；ZIP 只提取明确指定的可执行文件入口。
public enum ManagedToolExtraction: Sendable, Hashable {
    case executable
    case zip(entry: String)
}

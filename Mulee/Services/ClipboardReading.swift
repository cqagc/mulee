/// 只在用户启用监听时访问；测试提供内存实现。
protocol ClipboardReading {
    var changeCount: Int { get }
    var typeNames: Set<String> { get }
    func plainText() -> String?
}

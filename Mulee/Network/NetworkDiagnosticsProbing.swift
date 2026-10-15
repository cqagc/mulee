/// 注入系统探测，测试不需要访问真实网络。
nonisolated protocol NetworkDiagnosticsProbing: Sendable {
    func probe() async -> NetworkDiagnosticsSnapshot
}

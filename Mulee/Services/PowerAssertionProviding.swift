/// 封装系统电源断言：创建后返回 ID，用完按 ID 释放。方便测试时替换成假实现。
protocol PowerAssertionProviding {
    /// 创建「阻止空闲睡眠」断言；失败返回 nil。
    func createAssertion(reason: String) -> UInt32?
    func releaseAssertion(_ id: UInt32)
}

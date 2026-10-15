import Foundation

/// 运行环境判断。
enum AppEnvironment {
    /// 当前进程是不是单元测试的宿主 App。
    /// 测试宿主不能启动真实的下载引擎，否则会读写用户真实的会话和下载目录。
    static var isRunningUnitTests: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }
}

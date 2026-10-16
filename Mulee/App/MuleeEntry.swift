import MuleeCore
import SwiftUI

/// Native Messaging 模式不创建 App、窗口、引擎或任务存储。
@main enum MuleeEntry {
    @MainActor static func main() async {
        if CommandLine.arguments == [CommandLine.arguments[0], "--diagnose-network-only"] {
            let snapshot = await SystemNetworkDiagnosticsProbe().probe()
            // 命令行只输出结论，不记录物理接口、局域网或 WAN 地址。
            let result: String
            switch snapshot.publicIPv4Status {
            case .unknown: result = "未确认"
            case .noPublicIPv4: result = "运营商没有分配公网 IPv4"
            case .publicIPv4: result = "正常"
            }
            print(result)
            return
        }
        if VideoNativeMessaging.isNativeInvocation(CommandLine.arguments) {
            await VideoNativeMessaging.run(arguments: CommandLine.arguments)
        }
        MuleeApp.main()
    }
}

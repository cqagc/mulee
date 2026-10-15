import SwiftUI

/// Native Messaging 模式不创建 App、窗口、引擎或任务存储。
@main enum MuleeEntry {
    @MainActor static func main() async {
        if VideoNativeMessaging.isNativeInvocation(CommandLine.arguments) {
            await VideoNativeMessaging.run(arguments: CommandLine.arguments)
        }
        MuleeApp.main()
    }
}

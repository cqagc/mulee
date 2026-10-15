import SwiftUI

struct AppUpdateCommands: Commands {
    let updates: AppUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button("检查更新…", action: updates.checkForUpdates)
                .disabled(!updates.canCheckForUpdates)
        }
    }
}

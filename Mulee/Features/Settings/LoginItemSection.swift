import SwiftUI

struct LoginItemSection: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller = LoginItemController()

    var body: some View {
        Toggle("开机启动", isOn: Binding(
            get: { controller.isRegistered },
            set: { controller.setEnabled($0, settings: settings) }
        ))
        .onAppear(perform: refresh)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
        if controller.requiresApproval {
            Text("请在系统设置的「登录项」中批准 Mulee 开机启动。")
                .foregroundStyle(.secondary)
            Button("打开登录项", action: controller.openSettings)
        }
        if let issue = controller.issue {
            Text(issue).foregroundStyle(.secondary)
        }
    }

    private func refresh() { controller.refresh(settings: settings) }
}

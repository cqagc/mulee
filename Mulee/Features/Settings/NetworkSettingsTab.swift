import SwiftUI
import MuleeCore

/// 设置·网络：代理状态、端口与连通性、速度。
struct NetworkSettingsTab: View {
    var body: some View {
        Form {
            ProxyStatusCard()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            PortConnectivitySection()
            SpeedLimitSection()
        }
        .formStyle(.grouped)
    }
}

#Preview {
    NetworkSettingsTab()
        .environment(AppModel(networkStatus: MockData.proxiedNetwork))
        .environment(SettingsModel())
}

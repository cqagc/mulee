import SwiftUI

struct PublicTrackerSettingsSection: View {
    @Environment(SettingsModel.self) private var settings
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.publicTrackersEnabled) {
                Text("自动添加公共 tracker")
                Text("会向更多公共 tracker 公开你在下载该内容。私有种子不受影响。")
            }
            TextField("订阅地址", text: $settings.trackerSubscriptions, axis: .vertical)
                .lineLimit(2...5)
                .help("每行一个订阅，同一行用 | 分隔备用地址。仅接受 HTTP 和 HTTPS。")
            TextField("自定义 tracker", text: $settings.customTrackers, axis: .vertical)
                .lineLimit(2...4)
                .help("每行一个 UDP、HTTP 或 HTTPS 地址。无效地址会忽略，自定义地址优先，最多添加 50 条。")
            LabeledContent("上次更新") {
                if let date = app.publicTrackers?.updatedAt {
                    Text(date, format: .dateTime.year().month().day().hour().minute())
                } else {
                    Text("尚未更新")
                }
            }
            LabeledContent("可添加的 tracker") {
                Text("\(app.publicTrackers?.trackerCount ?? 0) 条")
            }
            Button(app.publicTrackers?.isUpdating == true ? "正在更新…" : "立即更新", action: updateNow)
                .disabled(!settings.publicTrackersEnabled || app.publicTrackers == nil || app.publicTrackers?.isUpdating == true)
            if let issue = app.publicTrackers?.issue {
                Text(issue)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("公共 tracker")
        } footer: {
            Text("启动时检查，每 24 小时最多自动更新一次。关闭后停止追加，已添加的 tracker 会保留。")
        }
    }

    private func updateNow() {
        app.publicTrackers?.updateNow()
    }
}

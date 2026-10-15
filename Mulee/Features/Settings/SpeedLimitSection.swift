import SwiftUI

/// 设置·网络：速度。
struct SpeedLimitSection: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("速度") {
            LabeledContent("全局下载限速") {
                Picker("全局下载限速", selection: $model.downloadLimit) {
                    ForEach(SettingsModel.downloadLimitOptions, id: \.self) { limit in
                        Text(Self.title(for: limit)).tag(limit)
                    }
                }
                .labelsHidden()
                .fixedSize()
            }
            LabeledContent {
                Picker("全局上传限速", selection: $model.uploadLimit) {
                    ForEach(SettingsModel.downloadLimitOptions, id: \.self) { limit in
                        Text(Self.title(for: limit)).tag(limit)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                Text("全局上传限速")
                Text("BT 和电驴共用；电驴上传越多，别人给你排队越靠前")
            }
            Toggle(isOn: $model.scheduledLimit) {
                Text("计划限速")
                Text("工作日 9:00–18:00 下载限制为 5 MB/s")
            }
            LabeledContent {
                HStack {
                    Slider(value: $model.diskCacheMB, in: SettingsModel.diskCacheRange, step: 32) {
                        Text("磁盘缓存")
                    }
                    .frame(width: 180)
                    Text("\(Int(model.diskCacheMB)) MB")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                }
            } label: {
                Text("磁盘缓存")
                Text("先在内存里攒成大块再写盘，减少 SSD 写入")
            }
        }
    }

    private static func title(for limit: Int) -> LocalizedStringKey {
        limit == 0 ? "不限速" : "\(limit) MB/s"
    }
}

#Preview {
    Form { SpeedLimitSection() }
        .formStyle(.grouped)
        .environment(SettingsModel())
}

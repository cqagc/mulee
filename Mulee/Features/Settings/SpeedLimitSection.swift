import SwiftUI

/// 设置·网络：速度。
struct SpeedLimitSection: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section("速度") {
            LabeledContent {
                Picker("全局下载限速", selection: $model.downloadLimit) {
                    ForEach(SettingsModel.downloadLimitOptions, id: \.self) { limit in
                        Text(Self.title(for: Double(limit))).tag(limit)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                Text("全局下载限速")
                Text("所有下载合计，按各引擎实际需求分配")
            }
            LabeledContent {
                Picker("全局上传限速", selection: $model.uploadLimit) {
                    ForEach(SettingsModel.uploadLimitOptions, id: \.self) { limit in
                        Text(Self.title(for: limit)).tag(limit)
                    }
                }
                .labelsHidden()
                .fixedSize()
            } label: {
                Text("全局上传限速")
                Text("BT 和电驴上传合计；电驴上传越多，别人给你排队越靠前")
            }
            Toggle(isOn: $model.scheduledLimit) {
                Text("计划限速")
                Text("工作日按以下时段限速；支持跨午夜，开始与结束相同时不生效")
            }
            if model.scheduledLimit {
                DatePicker("开始时间", selection: $model.scheduleStart, displayedComponents: .hourAndMinute)
                DatePicker("结束时间", selection: $model.scheduleEnd, displayedComponents: .hourAndMinute)
                Picker("时段内下载限速", selection: $model.scheduledDownloadLimit) {
                    ForEach(SettingsModel.downloadLimitOptions, id: \.self) { limit in
                        Text(Self.title(for: Double(limit))).tag(limit)
                    }
                }
                Picker("时段内上传限速", selection: $model.scheduledUploadLimit) {
                    ForEach(SettingsModel.uploadLimitOptions, id: \.self) { limit in
                        Text(Self.title(for: limit)).tag(limit)
                    }
                }
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
                Text("所有下载先在内存里攒成块再写盘，减少硬盘写入；突然断电最多需重新下载缓存中的部分")
            }
        }
    }

    private static func title(for limit: Double) -> LocalizedStringKey {
        limit == 0 ? "不限速" : "\(limit.formatted(.number)) MB/s"
    }
}

#Preview {
    Form { SpeedLimitSection() }
        .formStyle(.grouped)
        .environment(SettingsModel())
}

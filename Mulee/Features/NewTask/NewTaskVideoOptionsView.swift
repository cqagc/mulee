import SwiftUI

struct NewTaskVideoOptionsView: View {
    @Environment(SettingsModel.self) private var settings
    @Bindable var item: NewTaskLinkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Picker("画质", selection: $item.videoQuality) {
                    ForEach(NewTaskVideoQuality.allCases) { quality in
                        Text(quality.title).tag(quality)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Toggle("弹幕转 ASS", isOn: $item.danmakuToASS)
                    .fixedSize()
                Toggle("CC 字幕", isOn: $item.ccSubtitles)
                    .fixedSize()
            }
            .disabled(true)
            Text("使用全局视频设置，将在后续版本支持单独设置")
                .foregroundStyle(.secondary)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        .controlSize(.small)
        .padding(.leading, 68)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
        .onChange(of: VideoEngineConfiguration.configuration(from: settings), initial: true) {
            item.videoQuality = settings.videoQuality == .compatible ? .compatible1080p : .bestQuality
            item.danmakuToASS = settings.danmakuToASS
            item.ccSubtitles = settings.ccSubtitles
        }
    }
}

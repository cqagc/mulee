import SwiftUI

/// 设置·视频。
struct VideoSettingsTab: View {
    @Environment(SettingsModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("默认画质", selection: $model.videoQuality) {
                    Text("兼容优先").tag(SettingsModel.VideoQuality.compatible)
                    Text("画质优先").tag(SettingsModel.VideoQuality.best)
                }
                Text(model.videoQuality == .compatible
                    ? String(localized: "H.264/HEVC MP4，系统播放器和 iPhone 都能播")
                    : String(localized: "最高画质 MKV"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section("yt-dlp") {
                Picker("更新通道", selection: $model.ytDlpChannel) {
                    Text("稳定版").tag(SettingsModel.YtDlpChannel.stable)
                    Text("每日版").tag(SettingsModel.YtDlpChannel.nightly)
                }
                Text("网站改版时每日版修得最快")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle("下载失败时先更新 yt-dlp 再重试", isOn: $model.updateBeforeRetry)
            }
            Section("B 站") {
                Toggle("弹幕转 ASS", isOn: $model.danmakuToASS)
                Toggle("CC 字幕", isOn: $model.ccSubtitles)
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    VideoSettingsTab()
        .environment(SettingsModel())
}

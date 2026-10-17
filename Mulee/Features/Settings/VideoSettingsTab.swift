import SwiftUI
import MuleeCore

/// 设置·视频。
struct VideoSettingsTab: View {
    @Environment(SettingsModel.self) private var model
    @State private var subtitleLanguagesText = ""

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
            Section("下载选项") {
                Picker("音频格式", selection: $model.audioFormat) {
                    Text("M4A").tag(YtDlpOutputOptions.AudioFormat.m4a)
                    Text("MP3").tag(YtDlpOutputOptions.AudioFormat.mp3)
                }
                Picker("编码偏好", selection: $model.codecPreference) {
                    Text("自动").tag(YtDlpOutputOptions.CodecPreference.auto)
                    Text("H.264").tag(YtDlpOutputOptions.CodecPreference.h264)
                    Text("HEVC").tag(YtDlpOutputOptions.CodecPreference.hevc)
                    Text("AV1").tag(YtDlpOutputOptions.CodecPreference.av1)
                    Text("VP9").tag(YtDlpOutputOptions.CodecPreference.vp9)
                }
                Toggle("优先选择 60 帧", isOn: $model.prefer60fps)
                Picker("文件名", selection: $model.filenamePreset) {
                    Text("标题").tag(YtDlpOutputOptions.FilenamePreset.title)
                    Text("上传者与标题").tag(YtDlpOutputOptions.FilenamePreset.uploaderTitle)
                    Text("日期与标题").tag(YtDlpOutputOptions.FilenamePreset.dateTitle)
                }
                Toggle("嵌入元数据、封面和章节", isOn: $model.embedMetadata)
                Toggle("标记 YouTube 赞助片段", isOn: $model.sponsorBlockMark)
                Text("标记会访问 SponsorBlock 公共服务，仅添加章节，不删除视频内容。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("字幕（B 站除外）") {
                Picker("字幕保存方式", selection: $model.subtitleMode) {
                    Text("不下载").tag(YtDlpOutputOptions.SubtitleMode.off)
                    Text("嵌入视频").tag(YtDlpOutputOptions.SubtitleMode.embed)
                    Text("单独保存 SRT").tag(YtDlpOutputOptions.SubtitleMode.file)
                }
                TextField("首选语言（逗号分隔）", text: $subtitleLanguagesText)
                    .onChange(of: subtitleLanguagesText) { saveSubtitleLanguages() }
                Text("例如 zh-Hans,en；添加任务时可勾选视频提供的语言。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("包含自动字幕", isOn: $model.autoCaptions)
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
            VideoLoginSettingsView()
            Section("B 站") {
                Toggle("弹幕转 ASS", isOn: $model.danmakuToASS)
                Toggle("CC 字幕", isOn: $model.ccSubtitles)
            }
        }
        .formStyle(.grouped)
        .onAppear { subtitleLanguagesText = model.subtitleLanguages.joined(separator: ",") }
    }

    private func saveSubtitleLanguages() {
        model.subtitleLanguages = subtitleLanguagesText.components(separatedBy: CharacterSet(charactersIn: ",，"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

}

#if DEBUG
#Preview {
    VideoSettingsTab()
        .environment(SettingsModel())
}
#endif

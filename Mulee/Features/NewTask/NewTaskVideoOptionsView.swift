import SwiftUI
import MuleeCore

struct NewTaskVideoOptionsView: View {
    @Environment(SettingsModel.self) private var settings
    @Bindable var item: NewTaskLinkModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("视频格式", selection: $item.videoFormatID) {
                Text("跟随全局设置").tag("")
                ForEach(item.videoFormats) { format in
                    Text(formatLabel(format)).tag(format.id)
                }
            }
            if item.isLoadingVideoFormats {
                ProgressView("正在读取视频格式，仍可跟随全局设置添加…")
                    .controlSize(.small)
            }
            if let error = item.videoFormatsError {
                Text(error)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NewTaskVideoPartsView(item: item)
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        .controlSize(.small)
        .padding(.leading, 68)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
        .task(id: item.id) {
            await item.loadVideoFormats(remembered: item.videoSiteKey.flatMap { settings.videoFormatChoiceBySite[$0] }) { url, site in
                try await NewTaskVideoFormatProvider.shared.formats(
                    for: url, site: site, channel: settings.ytDlpChannel == .stable ? .stable : .nightly
                )
            }
        }
        .onChange(of: item.videoFormatID) {
            guard let site = item.videoSiteKey else { return }
            settings.videoFormatChoiceBySite[site] = item.videoFormatID.isEmpty ? nil : item.videoFormatID
        }
        .task(id: item.id) {
            await item.loadVideoParts { url in
                try await VideoPlaylistProvider.shared.entries(
                    for: url, channel: settings.ytDlpChannel == .stable ? .stable : .nightly
                )
            }
        }
        .onChange(of: VideoEngineConfiguration.configuration(from: settings), initial: true) {
            item.videoQuality = settings.videoQuality == .compatible ? .compatible1080p : .bestQuality
            item.danmakuToASS = settings.danmakuToASS
            item.ccSubtitles = settings.ccSubtitles
        }
    }

    private func formatLabel(_ format: YtDlpFormat) -> String {
        let size = format.size?.formatted(.byteCount(style: .file)) ?? String(localized: "大小未知")
        let login = format.needsLogin ? " · " + String(localized: "需要登录") : ""
        return "\(format.resolution) · \(format.codec) · \(size)\(login)"
    }

}

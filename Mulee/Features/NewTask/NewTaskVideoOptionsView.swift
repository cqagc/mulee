import SwiftUI
import MuleeCore

struct NewTaskVideoOptionsView: View {
    @Environment(SettingsModel.self) private var settings
    @Bindable var item: NewTaskLinkModel
    @State private var playlistReload = 0
    @State private var isAdvancedExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("视频格式", selection: $item.videoFormatID) {
                Text("跟随全局设置").tag("")
                Text(NewTaskVideoQuality.audioOnly.title).tag("mulee:audio")
                ForEach(item.videoFormats) { format in
                    Text(formatLabel(format)).tag(format.id)
                }
            }
            NewTaskVideoPartsView(item: item) { playlistReload += 1 }
            if item.isLoadingVideoFormats {
                ProgressView("正在读取视频格式，仍可跟随全局设置添加…")
                    .controlSize(.small)
            }
            if let error = item.videoFormatsError {
                Text(error)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !item.audioOnly, settings.subtitleMode != .off, item.videoSiteKey != "bilibili.com" {
                subtitleSelection
            }
            if item.showsVideoAdvancedOptions {
                DisclosureGroup(isExpanded: $isAdvancedExpanded) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text("开始时间")
                            TextField("开始时间", text: $item.videoSectionStart, prompt: Text("00:00"))
                                .labelsHidden()
                                .frame(width: 90)
                            Text("结束时间")
                            TextField("结束时间", text: $item.videoSectionEnd, prompt: Text("01:00"))
                                .labelsHidden()
                                .frame(width: 90)
                        }
                        Text("留空下载完整视频；可填写时:分:秒、分:秒或秒数。")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let error = item.videoSectionError {
                            Text(error)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Button {
                        isAdvancedExpanded.toggle()
                    } label: {
                        Text("高级选项")
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .toggleStyle(.checkbox)
        .font(.caption)
        .controlSize(.small)
        .padding(.leading, 68)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
        .task(id: item.videoFormatURL) {
            await item.loadVideoFormats(remembered: item.videoSiteKey.flatMap { settings.videoFormatChoiceBySite[$0] }) { url, site in
                try await NewTaskVideoFormatProvider.shared.metadata(
                    for: url, site: site, channel: settings.ytDlpChannel == .stable ? .stable : .nightly
                )
            }
        }
        .onChange(of: availableSubtitleLanguages, initial: true) {
            guard !item.didSelectSubtitleLanguages else { return }
            item.videoSubtitleLanguages = Set(YtDlpSubtitleLanguage.preferredIDs(
                in: availableSubtitleLanguages, preferences: settings.subtitleLanguages
            ))
        }
        .onChange(of: item.videoFormatID) {
            guard let site = item.videoSiteKey else { return }
            settings.videoFormatChoiceBySite[site] = item.videoFormatID.isEmpty || item.audioOnly ? nil : item.videoFormatID
        }
        .task(id: playlistReload) {
            await item.loadVideoParts(retry: playlistReload > 0) { url in
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

    private var availableSubtitleLanguages: [String] {
        let manual = item.videoMetadata?.subtitleLanguages ?? []
        let automatic = settings.autoCaptions ? item.videoMetadata?.automaticCaptionLanguages ?? [] : []
        return Set(manual + automatic).filter(YtDlpSubtitleLanguage.isValidID).sorted()
    }

    private var subtitleSelection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("字幕语言")
            ForEach(availableSubtitleLanguages, id: \.self) { language in
                Toggle(subtitleLabel(language), isOn: subtitleBinding(language))
            }
            if availableSubtitleLanguages.isEmpty, !item.isLoadingVideoFormats {
                Text("这个视频暂无可选字幕。")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func subtitleBinding(_ language: String) -> Binding<Bool> {
        Binding {
            item.videoSubtitleLanguages.contains(language)
        } set: { selected in
            item.didSelectSubtitleLanguages = true
            if selected { item.videoSubtitleLanguages.insert(language) }
            else { item.videoSubtitleLanguages.remove(language) }
        }
    }

    private func subtitleLabel(_ language: String) -> String {
        let name = Locale.current.localizedString(forLanguageCode: language) ?? language
        let automatic = item.videoMetadata?.subtitleLanguages.contains(language) != true
        let label = name + " (" + language + ")"
        return automatic ? label + " · " + String(localized: "自动字幕") : label
    }

    private func formatLabel(_ format: YtDlpFormat) -> String {
        let size = format.size?.formatted(.byteCount(style: .file)) ?? String(localized: "大小未知")
        let login = format.needsLogin ? " · " + String(localized: "需要登录") : ""
        return "\(format.resolution) · \(format.codec) · \(size)\(login)"
    }

}

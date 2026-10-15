import SwiftUI

struct NewTaskVideoOptionsView: View {
    @Bindable var item: NewTaskLinkModel

    var body: some View {
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
        .toggleStyle(.checkbox)
        .font(.caption)
        .controlSize(.small)
        .padding(.leading, 68)
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }
}

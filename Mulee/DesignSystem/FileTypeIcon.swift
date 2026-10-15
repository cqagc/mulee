import SwiftUI

/// 「虚实」文件类型图标。图形与角标字号是画布比例，不随正文大小改变。
struct FileTypeIcon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    let category: FileCategory
    let state: FileIconState
    let `extension`: String?
    var size: CGFloat = 32

    var body: some View {
        let metrics = FileIconMetrics(size: size)
        let palette = FileIconPalette(category: category, state: state, colorScheme: colorScheme)
        ZStack {
            FileIconSurface(state: state, metrics: metrics, palette: palette)
            FileIconGlyph(category: category, state: state, metrics: metrics, palette: palette)
        }
        .frame(width: size, height: size)
        .overlay(alignment: .bottomTrailing) {
            if let text = category.badgeText(filenameExtension: `extension`, size: size) {
                FileIconBadge(text: text, state: state, metrics: metrics, palette: palette)
            }
        }
        // 角标描边镂空后透出真实背景，适配详情栏材质以及亮暗总览。
        .compositingGroup()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: state)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(category.title) · \(state.title)")
    }
}

#Preview {
    HStack {
        FileTypeIcon(category: .video, state: .downloading(progress: 0.4), extension: "mkv", size: 64)
        FileTypeIcon(category: .video, state: .completed, extension: "mkv", size: 64)
        FileTypeIcon(category: .archive, state: .attention(progress: 0.4), extension: "rar", size: 64)
    }
    .padding()
}

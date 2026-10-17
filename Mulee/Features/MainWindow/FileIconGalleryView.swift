#if DEBUG
import SwiftUI

/// 同一窗口里强制展示两种外观，便于截图比较。
struct FileIconGalleryView: View {
    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 0) {
                FileIconGalleryPanel(title: String(localized: "亮色"), colorScheme: .light)
                    .environment(\.colorScheme, .light)
                FileIconGalleryPanel(title: String(localized: "暗色"), colorScheme: .dark)
                    .environment(\.colorScheme, .dark)
            }
        }
        .frame(width: 1120)
        .frame(minHeight: 720, idealHeight: 1380, maxHeight: 1380)
    }
}
#endif

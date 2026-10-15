#if DEBUG
import SwiftUI

struct FileIconGalleryPanel: View {
    let title: String
    let colorScheme: ColorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("虚实 · \(title)")
                .font(.title2.bold())
            Grid(horizontalSpacing: 16, verticalSpacing: 0) {
                GridRow {
                    Text("类别")
                        .frame(width: 88, alignment: .leading)
                    Text("下载中 40%")
                    Text("已完成")
                    Text("需要注意")
                    Text("引擎未接入")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                ForEach(FileCategory.allCases, id: \.self) { category in
                    FileIconGalleryRow(category: category)
                }
            }
            Divider()
            Text("32pt / 16pt · 下载中与已完成")
                .font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 16) {
                ForEach(FileCategory.allCases, id: \.self) { category in
                    FileIconGallerySmallSample(category: category)
                }
            }
        }
        .padding(20)
        .frame(width: 560)
        .foregroundStyle(.primary)
        .background(FileIconPalette(category: .other, state: .completed, colorScheme: colorScheme).canvas)
    }
}
#endif

import SwiftUI

struct FileIconGlyph: View {
    let category: FileCategory
    let state: FileIconState
    let metrics: FileIconMetrics
    let palette: FileIconPalette

    var body: some View {
        Group {
            if let symbol = category.symbol {
                Image(systemName: symbol.name)
                    .resizable()
                    .scaledToFit()
                    .frame(width: metrics.glyphSize, height: metrics.glyphSize)
            } else {
                Text(verbatim: "PDF")
                    .font(.system(size: metrics.side * 0.26, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(state.isCompleted ? .white : palette.glyph)
    }
}

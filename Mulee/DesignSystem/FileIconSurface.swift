import SwiftUI

struct FileIconSurface: View {
    let state: FileIconState
    let metrics: FileIconMetrics
    let palette: FileIconPalette

    var body: some View {
        let square = RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
        ZStack {
            ZStack(alignment: .bottom) {
                square.fill(palette.background)
                Rectangle()
                    .fill(palette.progress)
                    .frame(height: metrics.side * state.progress)
            }
            .clipShape(square)
            .overlay {
                square.stroke(palette.stroke, style: metrics.strokeStyle)
            }
            .opacity(state.isCompleted ? 0 : 1)

            square.fill(palette.completed)
                .opacity(state.isCompleted ? 1 : 0)
        }
        .frame(width: metrics.side, height: metrics.side)
    }
}

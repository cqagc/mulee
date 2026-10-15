import SwiftUI

struct FileIconBadge: View {
    let text: String
    let state: FileIconState
    let metrics: FileIconMetrics
    let palette: FileIconPalette

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: 9 * metrics.scale, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 4 * metrics.scale)
            .padding(.vertical, 2 * metrics.scale)
            .background(state.isCompleted ? palette.completedBadge : palette.stroke,
                        in: .rect(cornerRadius: 4 * metrics.scale))
            .overlay {
                RoundedRectangle(cornerRadius: 4 * metrics.scale, style: .continuous)
                    .stroke(.white, lineWidth: 2.5 * metrics.scale)
                    .blendMode(.destinationOut)
            }
            .padding(2 * metrics.scale)
    }
}

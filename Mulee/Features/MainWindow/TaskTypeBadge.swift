import SwiftUI

struct TaskTypeBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(.caption, design: .monospaced, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
            .fixedSize()
    }
}

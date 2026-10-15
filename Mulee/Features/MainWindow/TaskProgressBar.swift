import SwiftUI

struct TaskProgressBar: View {
    let progress: Double
    let style: TaskProgressStyle
    var height: CGFloat = Theme.progressBarHeight

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .overlay(alignment: .leading) {
                Canvas { context, size in
                    let width = size.width * min(1, max(0, progress))
                    let capsule = Capsule().path(in: CGRect(x: 0, y: 0, width: width, height: size.height))
                    context.clip(to: capsule)
                    if style == .waiting {
                        for x in stride(from: 0.0, to: width, by: 8) {
                            context.fill(Path(CGRect(x: x, y: 0, width: 5, height: size.height)), with: .color(style.color))
                        }
                    } else {
                        context.fill(capsule, with: .color(style.color))
                    }
                }
            }
            .frame(height: height)
            .accessibilityHidden(true)
    }
}

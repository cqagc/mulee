import SwiftUI

struct NetworkStatusRow: View {
    let title: String
    let value: String
    let isHealthy: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: MuleeSymbol.statusDot.name)
                .foregroundStyle(isHealthy ? Theme.success : Theme.wait)
                .imageScale(.small)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value)
        }
        .accessibilityElement(children: .combine)
    }
}

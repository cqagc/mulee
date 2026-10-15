import SwiftUI

struct InspectorLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            configuration.label
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            configuration.content
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

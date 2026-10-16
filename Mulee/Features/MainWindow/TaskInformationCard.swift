import SwiftUI

struct TaskInformationCard: View {
    let presentation: TaskPresentation

    var body: some View {
        InspectorCard("任务信息") {
            LabeledContent("类型", value: presentation.typeLabel)
            LabeledContent("大小", value: presentation.size)
            LabeledContent("状态", value: presentation.statusTitle)
            if presentation.metadata != presentation.size {
                Text(presentation.metadata)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

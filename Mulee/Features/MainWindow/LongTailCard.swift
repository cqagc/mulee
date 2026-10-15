import SwiftUI

struct LongTailCard: View {
    let presentation: TaskPresentation

    var body: some View {
        InspectorCard("长尾任务") {
            LabeledContent("状态", value: presentation.longTailStatus)
            LabeledContent("来源", value: presentation.sourceSummary)
            LabeledContent("完整源最后出现", value: presentation.lastCompleteSource)
            LabeledContent("已等待", value: presentation.waitingDuration)
            LabeledContent("实际传输时长", value: presentation.transferDuration)
        }
    }
}

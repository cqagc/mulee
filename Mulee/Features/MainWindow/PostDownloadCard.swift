import SwiftUI

struct PostDownloadCard: View {
    let presentation: TaskPresentation

    var body: some View {
        InspectorCard("完成后") {
            LabeledContent("自动解压", value: presentation.extractionSetting)
            LabeledContent("文件名编码", value: presentation.filenameEncoding)
            if let hash = presentation.hash {
                Text(hash)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

import AppKit
import SwiftUI

struct PostDownloadCard: View {
    let presentation: TaskPresentation

    var body: some View {
        if presentation.showsPostDownload {
            InspectorCard("完成后") {
                if let extractionSetting = presentation.extractionSetting {
                    LabeledContent("自动解压", value: extractionSetting)
                    LabeledContent("文件名编码", value: presentation.filenameEncoding)
                }
                if let status = presentation.extractionStatus {
                    LabeledContent("解压状态", value: status)
                }
                if presentation.task.status == .extracting {
                    ProgressView(value: presentation.progress) {
                        Text(presentation.progressText)
                    }
                }
                if let rule = presentation.task.postDownload.matchedRuleName {
                    LabeledContent("命中规则", value: rule)
                }
                if let failure = presentation.task.postDownload.extractionFailure {
                    Text("\(failure)。原压缩包已保留")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(presentation.extractedItems, id: \.self) { item in
                    LabeledContent(item.lastPathComponent) {
                        Button("在访达中显示", systemImage: MuleeSymbol.revealInFinder.name) {
                            reveal(item)
                        }
                    }
                }
                ForEach(presentation.task.postDownload.extractionWarnings ?? [], id: \.self) { warning in
                    Text(warning)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
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

    private func reveal(_ item: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([item])
    }
}

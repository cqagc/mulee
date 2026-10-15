import MuleeCore
import SwiftUI

struct BitTorrentInspectorView: View {
    @Environment(AppModel.self) private var appModel
    let task: DownloadTask
    @State private var model = BitTorrentFilesModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info = model.info {
                InspectorCard("BT 信息") {
                    LabeledContent("已连接节点", value: info.numPeers.formatted())
                    LabeledContent("做种者", value: info.numSeeds.formatted())
                    LabeledContent("分享率", value: info.ratio.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("私有种子", value: info.isPrivate ? String(localized: "是") : String(localized: "否"))
                }
            }
            Text("下载文件")
                .font(.headline)
            if let issue = model.issue {
                Text(issue)
                    .font(.caption)
                    .foregroundStyle(Theme.wait)
            }
            if model.files.isEmpty {
                Text("正在等待文件信息，获取后可选择要下载的文件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let selectedCount = model.selectedCount
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(model.files) { file in
                        BitTorrentFileRow(
                            file: file, model: model,
                            canChange: !model.isUpdating && (file.priority == 0 || selectedCount > 1)
                        )
                    }
                }
            }
        }
        .task(id: task.engineTaskID) {
            await model.watch(engine: appModel.bitTorrent?.engine, id: task.engineTaskID)
        }
    }
}

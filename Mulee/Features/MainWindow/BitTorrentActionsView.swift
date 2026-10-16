import MuleeCore
import SwiftUI

struct BitTorrentActionsView: View {
    @Environment(AppModel.self) private var model
    let task: DownloadTask

    var body: some View {
        Group {
            Button("移动存储位置…") { TaskActions.moveTorrentStorage(task, model: model) }
            Button("强制重新校验") { TaskActions.recheckTorrent(task, model: model) }
            Button("强制宣告") { TaskActions.reannounceTorrent(task, model: model) }
            Button("导出种子文件…") { TaskActions.exportTorrent(task, model: model) }
        }
        .disabled(task.engineTaskID == nil || model.bitTorrent == nil)
    }
}

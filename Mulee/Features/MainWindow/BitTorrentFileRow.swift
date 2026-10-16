import MuleeCore
import SwiftUI

struct BitTorrentFileRow: View {
    @Environment(AppModel.self) private var appModel
    let file: TorrentFileEntry
    let model: BitTorrentFilesModel
    let canChange: Bool

    private var selection: Binding<Bool> {
        Binding(get: { file.priority > 0 }, set: setSelected)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(file.path, isOn: selection)
                .toggleStyle(.checkbox)
                .disabled(!canChange)
                .lineLimit(2)
                .help(file.path)
            HStack {
                Text(file.size, format: .byteCount(style: .file))
                Spacer()
                Text(progress, format: .percent.precision(.fractionLength(0)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .accessibilityLabel("文件下载进度")
                .accessibilityValue(progress.formatted(.percent.precision(.fractionLength(0))))
            if StreamingPlayback.isVideo(file.path), let task = appModel.tasks.first(where: { $0.id == appModel.selectedTaskID }),
               StreamingPlayback.canPlay(task, files: [file]) {
                Button("播放", systemImage: "play.fill") {
                    StreamingPlayback.shared.play(task: task, engine: appModel.bitTorrent?.engine, file: file, coordinator: appModel.coordinator)
                }
                .help(file.path)
            }
            BitTorrentRenameView(path: file.path, model: model)
        }
    }

    private var progress: Double {
        BitTorrentFilesModel.progress(for: file)
    }

    private func setSelected(_ selected: Bool) {
        Task { await model.setSelected(selected, file: file) }
    }
}

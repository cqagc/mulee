import MuleeCore
import SwiftUI

struct BitTorrentFileRow: View {
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
        }
    }

    private var progress: Double {
        BitTorrentFilesModel.progress(for: file)
    }

    private func setSelected(_ selected: Bool) {
        Task { await model.setSelected(selected, file: file) }
    }
}

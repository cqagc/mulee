import SwiftUI

/// 由主窗口作为 sheet 呈现的新建下载面板。
struct NewTaskSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var draft: NewTaskModel

    init(draft: NewTaskModel = NewTaskModel()) {
        _draft = State(initialValue: draft)
    }

    var body: some View {
        @Bindable var draft = draft

        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("新建下载")
                    .font(.headline)
                Text("粘贴一个或多个链接，类型会自动识别。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)

            TextField("粘贴下载链接，每行一个", text: $draft.inputText, axis: .vertical)
                .font(.callout.monospaced())
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(.background, in: .rect(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.quaternary)
                }
                .padding(.horizontal, 22)
                .padding(.top, 14)

            Text("识别到 \(draft.linkCount) 个链接")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 22)
                .padding(.top, 16)
                .padding(.bottom, 8)

            ScrollView {
                if draft.links.isEmpty {
                    ContentUnavailableView("等待粘贴链接", systemImage: MuleeSymbol.add.name)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(draft.links) { item in
                            if item.id != draft.links.first?.id {
                                Divider()
                            }
                            NewTaskLinkRow(item: item)
                        }
                    }
                }
            }
            .frame(height: 360)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.quaternary)
            }
            .clipShape(.rect(cornerRadius: 10))
            .padding(.horizontal, 22)
            .padding(.bottom, 18)

            Divider()
            NewTaskFooterView(draft: draft, cancel: cancel, startDownload: startDownload)
        }
        .frame(width: 640)
        .onAppear(perform: consumePendingText)
    }

    private func consumePendingText() {
        draft.consumePendingText(from: model)
    }

    private func cancel() {
        dismiss()
    }

    private func startDownload() {
        guard draft.canStartDownload else { return }
        draft.createTasks(in: model)
        dismiss()
    }
}

#Preview("四种链接") {
    NewTaskSheet(draft: NewTaskModel(inputText: NewTaskPreviewData.inputText, parser: { _ in
        NewTaskPreviewData.links
    }))
    .environment(AppModel())
}

#Preview("等待粘贴") {
    NewTaskSheet()
        .environment(AppModel())
}

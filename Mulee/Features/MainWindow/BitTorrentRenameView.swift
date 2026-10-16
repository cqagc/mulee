import SwiftUI

struct BitTorrentRenameView: View {
    @Environment(AppModel.self) private var appModel
    let path: String
    let model: BitTorrentFilesModel
    @State private var isEditing = false
    @State private var name = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        if isEditing {
            VStack(alignment: .leading, spacing: 5) {
                TextField("新名称", text: $name)
                    .focused($isFocused)
                    .onSubmit(save)
                if let issue = BitTorrentManagementModel.renameValidation(name) {
                    Text(issue).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("保存", action: save)
                        .disabled(model.isUpdating || BitTorrentManagementModel.renameValidation(name) != nil)
                    Button("取消") { isEditing = false }
                }
            }
        } else {
            Button("重命名…") {
                name = path.split(separator: "/").last.map(String.init) ?? path
                isEditing = true
                isFocused = true
            }
            .disabled(model.isUpdating)
        }
    }

    private func save() {
        guard let newPath = BitTorrentManagementModel.renamedPath(path, name: name) else { return }
        let id = model.engineTaskID
        Task {
            await model.rename(path: path, to: newPath)
            if let id { await appModel.bitTorrent?.refreshTaskLocation(id) }
            if model.issue == nil { isEditing = false }
        }
    }
}

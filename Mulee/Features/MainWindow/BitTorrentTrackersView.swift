import MuleeCore
import SwiftUI

struct BitTorrentTrackersView: View {
    let model: BitTorrentManagementModel
    @State private var editingURL: String?
    @State private var address = ""
    @State private var isAdding = false

    var body: some View {
        InspectorCard("节点服务器（tracker）") {
            ForEach(model.trackers, id: \.url) { tracker in
                VStack(alignment: .leading, spacing: 6) {
                    Text(tracker.url)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                    Text(BitTorrentManagementModel.trackerState(tracker))
                    Text(BitTorrentManagementModel.trackerResult(tracker))
                        .foregroundStyle(.secondary)
                    LabeledContent("节点数", value: tracker.peers.formatted())
                    HStack {
                        Button("编辑…") {
                            editingURL = tracker.url
                            address = tracker.url
                            isAdding = false
                        }
                        Button("删除", role: .destructive) { remove(tracker.url) }
                        if tracker.status == "disabled", tracker.subscription {
                            Button("恢复") { restore(tracker.url) }
                        }
                    }
                    if editingURL == tracker.url, !isAdding { editor }
                }
                Divider()
            }
            if model.trackers.isEmpty {
                Text("尚无节点服务器，可添加地址以寻找更多来源。")
                    .foregroundStyle(.secondary)
            }
            if isAdding { editor }
            Button("添加节点服务器…") {
                editingURL = nil
                address = ""
                isAdding = true
            }
        }
        .disabled(model.isUpdating)
    }

    private var candidate: [TorrentTracker] {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if isAdding { return model.trackerConfigurations + [TorrentTracker(url: text)] }
        return model.trackerConfigurations.map {
            $0.url == editingURL ? TorrentTracker(url: text, tier: $0.tier) : $0
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("节点服务器地址", text: $address)
                .onSubmit(save)
            if let issue = BitTorrentManagementModel.trackerValidation(candidate.map(\.url)) {
                Text(issue).foregroundStyle(.secondary)
            }
            HStack {
                Button("保存", action: save)
                    .disabled(BitTorrentManagementModel.trackerValidation(candidate.map(\.url)) != nil)
                Button("取消") { editingURL = nil; isAdding = false }
            }
        }
    }

    private func save() {
        let configurations = candidate
        guard BitTorrentManagementModel.trackerValidation(configurations.map(\.url)) == nil else { return }
        Task {
            await model.saveTrackers(configurations)
            if model.issue == nil { editingURL = nil; isAdding = false }
        }
    }

    private func remove(_ url: String) {
        Task { await model.saveTrackers(model.trackerConfigurations.filter { $0.url != url }) }
    }

    private func restore(_ url: String) {
        let configurations = model.trackerConfigurations.map {
            $0.url == url ? TorrentTracker(url: $0.url, tier: $0.tier, subscription: false) : $0
        }
        Task { await model.saveTrackers(configurations) }
    }
}

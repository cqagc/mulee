import MuleeCore
import SwiftUI

struct BitTorrentPeersView: View {
    let model: BitTorrentManagementModel
    @State private var pendingBan: String?

    var body: some View {
        InspectorCard("已连接节点") {
            if model.peers.isEmpty {
                Text("暂时没有连接的节点，找到来源后会自动更新。")
                    .foregroundStyle(.secondary)
            }
            ForEach(Array(model.peers.enumerated()), id: \.offset) { _, peer in
                VStack(alignment: .leading, spacing: 5) {
                    Text(BitTorrentManagementModel.peerAddress(peer))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    LabeledContent("客户端", value: peer.client.isEmpty ? String(localized: "未知") : peer.client)
                    LabeledContent("进度", value: BitTorrentManagementModel.peerProgress(peer))
                    LabeledContent("下载速度", value: BitTorrentManagementModel.peerSpeed(peer.downloadRate))
                    LabeledContent("上传速度", value: BitTorrentManagementModel.peerSpeed(peer.uploadRate))
                    LabeledContent("来源", value: BitTorrentManagementModel.peerSources(peer.sources))
                    LabeledContent("连接类型", value: BitTorrentManagementModel.peerConnection(peer.connection))
                    Button("封禁此 IP…", role: .destructive) { pendingBan = peer.address }
                }
                .contextMenu {
                    Button("封禁此 IP…", role: .destructive) { pendingBan = peer.address }
                }
                Divider()
            }
        }
        .disabled(model.isUpdating)
        .confirmationDialog("封禁此 IP？", isPresented: confirmsBan, titleVisibility: .visible) {
            Button("封禁此 IP", role: .destructive) {
                if let address = pendingBan { Task { await model.ban(address) } }
            }
            Button("取消", role: .cancel) { pendingBan = nil }
        } message: {
            Text("此地址的连接将断开，重新启动后仍会阻止连接。")
        }
    }

    private var confirmsBan: Binding<Bool> {
        Binding(get: { pendingBan != nil }, set: { if !$0 { pendingBan = nil } })
    }
}

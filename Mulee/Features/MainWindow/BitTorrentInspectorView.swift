import MuleeCore
import SwiftUI

struct BitTorrentInspectorView: View {
    @Environment(AppModel.self) private var appModel
    let task: DownloadTask
    let model: BitTorrentFilesModel
    @State private var showsConnections = false

    private var sequentialDownload: Binding<Bool> {
        Binding(get: { model.info?.sequentialDownload ?? false }, set: setSequentialDownload)
    }

    private var firstLastPriority: Binding<Bool> {
        Binding(get: { model.info?.firstLastPriority ?? false }, set: setFirstLastPriority)
    }

    init(task: DownloadTask, model: BitTorrentFilesModel, showsConnections: Bool = false) {
        self.task = task
        self.model = model
        _showsConnections = State(initialValue: showsConnections)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let info = model.info {
                InspectorCard("BT 信息") {
                    LabeledContent("已连接节点", value: (model.diagnostics?.connectedPeers ?? info.numPeers).formatted())
                    LabeledContent("做种者", value: info.numSeeds.formatted())
                    LabeledContent("分享率", value: info.ratio.formatted(.number.precision(.fractionLength(2))))
                    LabeledContent("私有种子", value: info.isPrivate ? String(localized: "是") : String(localized: "否"))
                }
            }
            DisclosureGroup("连接详情", isExpanded: $showsConnections) {
                connectionDetails
                    .padding(.top, 8)
            }
            .font(.caption)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.45), in: .rect(cornerRadius: Theme.cardCornerRadius))
            InspectorCard("下载方式") {
                Toggle("按顺序下载", isOn: sequentialDownload)
                    .toggleStyle(.checkbox)
                Toggle("优先下载文件首尾", isOn: firstLastPriority)
                    .toggleStyle(.checkbox)
                Text("便于边下边预览，但可能让整体完成变慢。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .disabled(model.info == nil || model.isUpdating)
            Text("下载文件")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
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
        .onChange(of: task.engineTaskID) { showsConnections = false }
        .task(id: task.engineTaskID) {
            await model.watch(engine: appModel.bitTorrent?.engine, id: task.engineTaskID)
        }
    }

    @ViewBuilder
    private var connectionDetails: some View {
        if let diagnostics = model.diagnostics {
            VStack(alignment: .leading, spacing: 9) {
                Text("节点来源")
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                let sources = BitTorrentFilesModel.sourceRows(diagnostics.peerSources)
                if sources.isEmpty {
                    Text("尚未取得节点来源信息")
                        .foregroundStyle(.secondary)
                }
                ForEach(sources, id: \.title) { source in
                    LabeledContent(source.title, value: source.count.formatted())
                }
                Text("同一节点可能来自多个途径，来源数量不相加。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                LabeledContent("IPv4 / IPv6", value: "\(diagnostics.ipv4.formatted()) / \(diagnostics.ipv6.formatted())")
                    .accessibilityLabel("网络地址类型")
                    .accessibilityValue("IPv4，\(diagnostics.ipv4)；IPv6，\(diagnostics.ipv6)")
                LabeledContent("TCP / UDP（uTP）", value: "\(diagnostics.tcp.formatted()) / \(diagnostics.utp.formatted())")
                    .accessibilityLabel("连接协议")
                    .accessibilityValue("TCP，\(diagnostics.tcp)；UDP（uTP），\(diagnostics.utp)")
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    Text("节点服务器（tracker）")
                        .foregroundStyle(.secondary)
                    Text(BitTorrentFilesModel.trackerSummary(diagnostics))
                    if diagnostics.trackersPending > 0 {
                        Text("等待响应 \(diagnostics.trackersPending) 个")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                if let error = BitTorrentFilesModel.trackerError(diagnostics.lastTrackerError) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("最近一次连接问题")
                            .foregroundStyle(.secondary)
                        Text(error)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityElement(children: .combine)
                }
                Divider()
                Label(BitTorrentFilesModel.diskMessage(diagnostics.diskBacklogged),
                      systemImage: diagnostics.diskBacklogged == true ? MuleeSymbol.waitingForSources.name : MuleeSymbol.fileDiskImage.name)
                    .foregroundStyle(diagnostics.diskBacklogged == true ? Theme.wait : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("硬盘写入情况反映所有 BT 任务。")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let blocked = BitTorrentFilesModel.blockedClientsMessage(diagnostics.blockedClientsCount) {
                    Text(blocked)
                        .foregroundStyle(.secondary)
                }
            }
            .labeledContentStyle(InspectorLabeledContentStyle())
            .monospacedDigit()
        } else {
            Text("正在等待连接信息")
                .foregroundStyle(.secondary)
        }
    }

    private func setSequentialDownload(_ enabled: Bool) {
        let firstLast = model.info?.firstLastPriority ?? false
        Task { await model.setDownloadMode(sequentialDownload: enabled, firstLastPriority: firstLast) }
    }

    private func setFirstLastPriority(_ enabled: Bool) {
        let sequential = model.info?.sequentialDownload ?? false
        Task { await model.setDownloadMode(sequentialDownload: sequential, firstLastPriority: enabled) }
    }
}

#if DEBUG
#Preview("连接详情 · 深色") {
    if let task = MockData.tasks.first(where: { $0.kind == .bittorrent }),
       let model = try? BitTorrentFilesModel.preview(id: task.engineTaskID) {
        ScrollView {
            BitTorrentInspectorView(task: task, model: model, showsConnections: true)
                .padding(18)
        }
        .frame(width: 300, height: 1000)
        .preferredColorScheme(.dark)
        .environment(AppModel(tasks: []))
    }
}
#endif

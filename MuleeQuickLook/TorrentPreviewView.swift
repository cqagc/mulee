import SwiftUI

struct TorrentPreviewView: View {
    let model: TorrentPreviewModel?
    let isTooLarge: Bool
    private let bundle = Bundle(for: PreviewViewController.self)

    var body: some View {
        Group {
            if let model {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: model.name)
                                .font(.title2.bold())
                                .accessibilityAddTraits(.isHeader)
                            LabeledContent {
                                Text(model.totalSize, format: .byteCount(style: .file))
                            } label: {
                                Text("总大小", bundle: bundle)
                            }
                            LabeledContent {
                                Text(model.fileCount, format: .number.grouping(.never))
                            } label: {
                                Text("文件数", bundle: bundle)
                            }
                            LabeledContent {
                                Text(verbatim: model.version)
                            } label: {
                                Text("种子版本", bundle: bundle)
                            }
                            LabeledContent {
                                if model.isPrivate {
                                    Text("是", bundle: bundle)
                                } else {
                                    Text("否", bundle: bundle)
                                }
                            } label: {
                                Text("私有种子", bundle: bundle)
                            }
                            LabeledContent {
                                if let creator = model.createdBy {
                                    Text(verbatim: creator)
                                } else {
                                    Text("未注明", bundle: bundle)
                                }
                            } label: {
                                Text("创建工具", bundle: bundle)
                            }
                        }
                        Divider()
                        LazyVStack(alignment: .leading, spacing: 8) {
                            Text("文件树", bundle: bundle)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            ForEach(model.rows) { row in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Image(systemName: row.size == nil ? MuleeSymbol.fileFolder.name : MuleeSymbol.fileOther.name)
                                        .foregroundStyle(.secondary)
                                        .accessibilityHidden(true)
                                    Text(verbatim: row.name)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    if let size = row.size {
                                        Text(size, format: .byteCount(style: .file))
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, CGFloat(min(row.depth, 12)) * 16)
                                .accessibilityElement(children: .combine)
                                .help(row.path)
                            }
                            if model.remainingFileCount > 0 {
                                Text("还有 \(model.remainingFileCount) 个文件", bundle: bundle)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Divider()
                        LazyVStack(alignment: .leading, spacing: 12) {
                            Text("Tracker 列表", bundle: bundle)
                                .font(.headline)
                                .accessibilityAddTraits(.isHeader)
                            if model.trackerTiers.isEmpty {
                                Text("未提供 Tracker", bundle: bundle)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.trackerTiers.indices, id: \.self) { index in
                                LazyVStack(alignment: .leading, spacing: 4) {
                                    Text("第 \(index + 1) 层", bundle: bundle)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    ForEach(model.trackerTiers[index].indices, id: \.self) { trackerIndex in
                                        Text(verbatim: model.trackerTiers[index][trackerIndex])
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    .padding(24)
                    .textSelection(.enabled)
                }
            } else {
                VStack(spacing: 12) {
                    Text("无法读取这个种子文件", bundle: bundle)
                        .font(.headline)
                    if isTooLarge {
                        Text("文件大于 20 MB，无法预览", bundle: bundle)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.background)
    }
}

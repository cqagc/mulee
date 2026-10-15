import AppKit
import MuleeCore
import SwiftUI
import UniformTypeIdentifiers

struct TaskFileIcon: View {
    let task: DownloadTask
    var size: CGFloat = 34

    private var contentType: UTType {
        if case .bittorrent(let files, _, _, _) = task.detail, files > 1 { return .folder }
        return task.fileExtension.flatMap { UTType(filenameExtension: $0) } ?? .data
    }

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: contentType))
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size + 4)
            .accessibilityHidden(true)
    }
}

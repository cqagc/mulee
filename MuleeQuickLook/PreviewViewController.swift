import AppKit
import QuickLookUI
import SwiftUI

final class PreviewViewController: NSViewController, QLPreviewingController {
    override func loadView() {
        view = NSView()
        preferredContentSize = NSSize(width: 720, height: 640)
    }

    func preparePreviewOfFile(at url: URL) async throws {
        let content: TorrentPreviewView
        do {
            let model = try await Task.detached(priority: .userInitiated) {
                try TorrentPreviewModel.load(from: url)
            }.value
            content = TorrentPreviewView(model: model, isTooLarge: false)
        } catch {
            content = TorrentPreviewView(model: nil, isTooLarge: (error as? TorrentPreviewError) == .tooLarge)
        }
        let host = NSHostingController(rootView: content)
        for child in children {
            child.view.removeFromSuperview()
            child.removeFromParent()
        }
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }
}

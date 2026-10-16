import AppKit

/// 退出确认后立即收起窗口；保存超过 300ms 才显示非模态进度面板。
@MainActor
final class ShutdownProgressController {
    private(set) var isActive = false
    private(set) var panel: NSPanel?
    private var presentationTask: Task<Void, Never>?
    private var hiddenWindows: [NSWindow] = []

    func begin(windows: [NSWindow] = NSApp.windows, delay: Duration = .milliseconds(300)) {
        guard !isActive else { return }
        isActive = true
        hiddenWindows = windows.filter(\.isVisible)
        for window in hiddenWindows { window.orderOut(nil) }
        presentationTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self, isActive else { return }
            let panel = makePanel()
            self.panel = panel
            panel.center()
            panel.orderFrontRegardless()
            NSAccessibility.post(element: panel, notification: .created)
        }
    }

    func finish(restoreWindows: Bool = false) {
        isActive = false
        presentationTask?.cancel()
        presentationTask = nil
        panel?.orderOut(nil)
        panel = nil
        if restoreWindows {
            for window in hiddenWindows { window.orderFront(nil) }
        }
        hiddenWindows.removeAll()
    }

    private func makePanel() -> NSPanel {
        let title = String(localized: "正在退出 Mulee")
        let message = String(localized: "正在保存下载进度…")
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 144),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.title = title
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.level = .floating
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.backgroundColor = .windowBackgroundColor
        panel.setAccessibilityLabel(title)

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.setAccessibilityElement(false)
        icon.translatesAutoresizingMaskIntoConstraints = false
        let heading = NSTextField(labelWithString: title)
        heading.font = .preferredFont(forTextStyle: .headline)
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .preferredFont(forTextStyle: .subheadline)
        detail.textColor = .secondaryLabelColor
        let progress = NSProgressIndicator()
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.setAccessibilityLabel(message)
        progress.startAnimation(nil)
        let status = NSStackView(views: [progress, detail])
        status.spacing = 8
        status.alignment = .centerY
        let text = NSStackView(views: [heading, status])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 8
        let content = NSStackView(views: [icon, text])
        content.spacing = 20
        content.alignment = .centerY
        content.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(content)
        panel.contentView = view
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
            content.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            content.topAnchor.constraint(equalTo: view.topAnchor, constant: 36),
            content.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -28)
        ])
        return panel
    }
}

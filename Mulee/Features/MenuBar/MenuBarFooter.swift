import AppKit
import MuleeCore
import SwiftUI

/// 面板底部：全部暂停/继续、打开主窗口、网络状态，以及防睡眠说明。
struct MenuBarFooter: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    let pauseResumeAction: MenuBarPresentation.PauseResumeAction

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                switch pauseResumeAction {
                case .pauseAll:
                    Button("全部暂停", systemImage: MuleeSymbol.pause.name, action: pauseAll)
                case .resumeAll:
                    Button("全部继续", systemImage: MuleeSymbol.resume.name, action: resumeAll)
                }
                Button("打开 Mulee", action: openMain)
                Spacer()
                networkStatus
            }
            .controlSize(.small)
            Label("下载时阻止睡眠 · 全部完成后允许睡眠", systemImage: MuleeSymbol.preventSleep.name)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var networkStatus: some View {
        let (color, title) = statusStyle
        HStack(spacing: 4) {
            Image(systemName: MuleeSymbol.statusDot.name)
                .imageScale(.small)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var statusStyle: (Color, String) {
        switch model.networkStatus.ed2kID {
        case .high: (Theme.success, NetworkPresentation.ed2kID(.high).text)
        case .low: (Theme.wait, NetworkPresentation.ed2kID(.low).text)
        case .disconnected: (Color.secondary, String(localized: "未连接"))
        }
    }

    private func pauseAll() {
        model.pauseAll()
    }

    private func resumeAll() {
        model.resumeAll()
    }

    private func openMain() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

#Preview {
    MenuBarFooter(pauseResumeAction: .pauseAll)
        .environment(AppModel())
        .padding()
        .frame(width: 340)
}

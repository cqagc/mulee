import SwiftUI

/// 设置窗口的标签页。标题与图标见 Design/ICONS.md。
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case download
    case network
    case bittorrent
    case ed2k
    case video
    case unzip

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "通用"
        case .download: "下载"
        case .network: "网络"
        case .bittorrent: "BT"
        case .ed2k: "电驴"
        case .video: "视频"
        case .unzip: "解压"
        }
    }

    var symbol: MuleeSymbol {
        switch self {
        case .general: .settingsGeneral
        case .download: .downloading
        case .network: .network
        case .bittorrent: .bittorrent
        case .ed2k: .ed2k
        case .video: .video
        case .unzip: .statusExtracting
        }
    }
}

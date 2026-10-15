import Foundation

/// 面板中的种子文件及其选择状态，大小单位为字节。
struct TorrentFile: Identifiable {
    let name: String
    let size: Int64
    var isSelected = true

    var id: String { name }
}

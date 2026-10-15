/// 仅为原型指定的示例磁力链接提供文件列表，不模拟其他资源的元数据。
struct ExampleTorrentMetadataProvider: TorrentMetadataProvider {
    func files(for infoHash: String) -> [TorrentFile]? {
        guard infoHash == "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c" else { return nil }
        return [
            TorrentFile(name: "Big.Buck.Bunny.2160p.mkv", size: 2_400_000_000),
            TorrentFile(name: "Big.Buck.Bunny.2160p.zh-Hans.srt", size: 48_000),
            TorrentFile(name: "Making.Of.1080p.mp4", size: 512_000_000),
            TorrentFile(name: "Big.Buck.Bunny.4320p.HDR.mkv", size: 5_500_000_000, isSelected: false)
        ]
    }
}

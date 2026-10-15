/// 引擎接入前的文件列表来源；nil 表示元数据尚未获取。
protocol TorrentMetadataProvider {
    func files(for infoHash: String) -> [TorrentFile]?
}

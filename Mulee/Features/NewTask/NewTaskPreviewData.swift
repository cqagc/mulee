#if DEBUG
import Foundation
import MuleeCore

/// 预览直接注入解析结果，不依赖尚未接入的链接解析实现。
enum NewTaskPreviewData {
    static let inputText = """
    magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny
    ed2k://|file|超魔法大戰 繁中版.rar|641728512|9F3A0C5E57A13BC448B62A7CB71DC21B|/
    thunder://QUFodHRwczovL2V4YW1wbGUuY29tL3NpbnRlbC1vc3QuemlwWlo=
    https://www.bilibili.com/video/BV1xx411c7XX
    """

    static var links: [ParsedLink] {
        guard let archiveURL = URL(string: "https://example.com/sintel-ost.zip"),
              let videoURL = URL(string: "https://www.bilibili.com/video/BV1xx411c7XX") else {
            preconditionFailure("预览链接必须是有效 URL")
        }
        let originals = inputText.components(separatedBy: "\n")
        return [
            .magnet(
                infoHash: "dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c",
                displayName: "Big Buck Bunny 4K 合集",
                original: originals[0]
            ),
            .ed2k(
                fileName: "超魔法大戰 繁中版.rar",
                size: 641_728_512,
                hash: "9F3A0C5E57A13BC448B62A7CB71DC21B",
                original: originals[1]
            ),
            .http(url: archiveURL, decodedFromThunder: true, original: originals[2]),
            .video(url: videoURL, site: .bilibili, original: originals[3])
        ]
    }
}
#endif

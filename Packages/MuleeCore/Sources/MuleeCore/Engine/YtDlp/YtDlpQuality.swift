/// 画质参数为纯函数，方便预览与测试。
public enum YtDlpQuality: String, Codable, Sendable {
    case compatible
    case best

    public func arguments(codecPreference: YtDlpOutputOptions.CodecPreference) -> [String] {
        var result = arguments
        // 显式偏好必须能选到 AV1/VP9；容器仍跟随画质档位，auto 完全保留既有选择器。
        if codecPreference != .auto, self == .compatible { result[1] = "bv*+ba/b" }
        return result
    }

    public var arguments: [String] {
        switch self {
        case .compatible:
            [
                "--format", "bv[vcodec~='^(avc1|h264)']+ba[acodec~='^(mp4a|aac)']/bv[vcodec~='^(hev1|hvc1|hevc)']+ba[acodec~='^(mp4a|aac)']/b[vcodec~='^(avc1|h264|hev1|hvc1|hevc)'][acodec~='^(mp4a|aac)']/b[ext=mp4][vcodec~=?'^(avc1|h264|hev1|hvc1|hevc)'][acodec~=?'^(mp4a|aac)']",
                "--merge-output-format", "mp4", "--remux-video", "mp4"
            ]
        case .best:
            ["--format", "bv*+ba/b", "--merge-output-format", "mkv", "--remux-video", "mkv"]
        }
    }
}

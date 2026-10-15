import Foundation

/// 解析由引擎模板产生的 JSON。每个格式独立累计，避免音轨开始时进度归零。
struct YtDlpProgress: Sendable {
    private var received: [String: Int64] = [:]
    private var totals: [String: Int64] = [:]
    private var expectedFormats = 1
    private(set) var totalBytes: Int64?
    private(set) var receivedBytes: Int64 = 0
    private(set) var rate: Int64 = 0
    private(set) var eta: Double?
    private(set) var postProcessing = false
    private(set) var title: String?
    private(set) var videoCodec: String?
    private(set) var videoSize: CGSize?
    private(set) var finalPath: String?

    mutating func consume(_ line: String) -> Bool {
        guard line.hasPrefix("MULEE:"),
              let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any],
              let event = object["event"] as? String else { return false }
        switch event {
        case "metadata":
            if let value = object["title"] as? String {
                let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, value != "NA" { title = String(value.prefix(512)) }
            }
            videoCodec = object["vcodec"] as? String
            videoSize = Self.dimensions(object)
            if let formats = object["formats"] as? [[String: Any]], !formats.isEmpty {
                expectedFormats = formats.count
                for format in formats {
                    if videoSize == nil { videoSize = Self.dimensions(format) }
                    let id = format["format_id"] as? String ?? "default"
                    if let size = (Self.number(format["filesize"]) ?? Self.number(format["filesize_approx"])), size > 0 {
                        totals[id] = size
                    }
                }
            } else if let size = Self.number(object["total"]), size > 0 {
                totals[object["format"] as? String ?? "default"] = size
            }
        case "progress":
            let id = object["format"] as? String ?? "default"
            if let total = Self.number(object["total"]), total > 0 { totals[id] = total }
            let completed = object["status"] as? String == "finished"
            let amount = max(0, Self.number(object["downloaded"]) ?? (completed ? totals[id] ?? 0 : 0))
            received[id] = max(received[id] ?? 0, amount)
            rate = max(0, Self.number(object["speed"]) ?? 0)
            eta = (object["eta"] as? NSNumber)?.doubleValue
        case "postprocess":
            postProcessing = true
            rate = 0
        case "file":
            finalPath = object["path"] as? String
        default:
            return false
        }
        receivedBytes = received.values.reduce(0, +)
        totalBytes = totals.count >= expectedFormats ? max(receivedBytes, totals.values.reduce(0, +)) : nil
        return true
    }

    private static func number(_ value: Any?) -> Int64? {
        guard let value = value as? NSNumber, value.doubleValue.isFinite,
              value.doubleValue >= 0, value.doubleValue < Double(Int64.max) else { return nil }
        return value.int64Value
    }

    private static func dimensions(_ object: [String: Any]) -> CGSize? {
        guard let width = object["width"] as? NSNumber, let height = object["height"] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue > 0, height.doubleValue > 0 else { return nil }
        return CGSize(width: width.doubleValue, height: height.doubleValue)
    }

    static let metadataTemplate = #"before_dl:MULEE:{"event":"metadata","title":%(title)j,"vcodec":%(vcodec)j,"width":%(width)j,"height":%(height)j,"format":%(format_id)j,"total":%(filesize,filesize_approx)j,"formats":%(requested_formats)j}"#
    static let downloadTemplate = #"download:MULEE:{"event":"progress","format":%(info.format_id)j,"status":%(progress.status)j,"downloaded":%(progress.downloaded_bytes)j,"total":%(progress.total_bytes,progress.total_bytes_estimate)j,"speed":%(progress.speed)j,"eta":%(progress.eta)j}"#
    static let postprocessTemplate = #"postprocess:MULEE:{"event":"postprocess"}"#
    static let fileTemplate = #"after_move:MULEE:{"event":"file","path":%(filepath)j}"#
}

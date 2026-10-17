import Foundation

public enum BatchURLExpander {
    public enum ExpansionError: String, Error, LocalizedError {
        case tooMany = "单条链接展开超过 1000 个，请缩小范围。"
        case invalidRange = "批量范围无效，请使用递增的数字或字母范围。"
        public var errorDescription: String? {
            switch self {
            case .tooMany: String(localized: "单条链接展开超过 1000 个，请缩小范围。", bundle: .module)
            case .invalidRange: String(localized: "批量范围无效，请使用递增的数字或字母范围。", bundle: .module)
            }
        }
    }

    public static func expand(_ text: String, limit: Int = 1000) throws -> [String] {
        var count = 1
        var segments: [(prefix: String, values: [String])] = []
        var start = text.startIndex
        for match in text.matches(of: #/\[([0-9]+|[a-zA-Z])-([0-9]+|[a-zA-Z])\]/#) {
            let first = String(match.1)
            let last = String(match.2)
            let values: [String]
            if first.utf8.allSatisfy({ (48...57).contains($0) }), last.utf8.allSatisfy({ (48...57).contains($0) }) {
                guard let lower = Int64(first), let upper = Int64(last), lower <= upper else { throw ExpansionError.invalidRange }
                guard upper - lower < 1000 else { throw ExpansionError.tooMany }
                let size = Int(upper - lower + 1)
                guard count <= min(1000, limit) / size else { throw ExpansionError.tooMany }
                let width = first.hasPrefix("0") ? first.count : 0
                values = (lower...upper).map { number in
                    let value = String(number)
                    return String(repeating: "0", count: max(0, width - value.count)) + value
                }
            } else {
                guard let lower = first.utf8.first, let upper = last.utf8.first,
                      first.utf8.count == 1, last.utf8.count == 1,
                      ((97...122).contains(lower) && (97...122).contains(upper))
                        || ((65...90).contains(lower) && (65...90).contains(upper)), lower <= upper else {
                    throw ExpansionError.invalidRange
                }
                values = (lower...upper).map { String(UnicodeScalar($0)) }
            }
            guard count <= min(1000, limit) / values.count else { throw ExpansionError.tooMany }
            count *= values.count
            segments.append((String(text[start..<match.range.lowerBound]), values))
            start = match.range.upperBound
        }
        guard count <= limit else { throw ExpansionError.tooMany }
        var results = [""]
        for segment in segments {
            results = results.flatMap { result in segment.values.map { result + segment.prefix + $0 } }
        }
        return results.map { $0 + text[start...] }
    }
}

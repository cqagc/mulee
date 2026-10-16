import Foundation

public enum BatchURLExpander {
    public enum ExpansionError: String, Error, LocalizedError {
        case tooMany = "单条链接展开超过 1000 个，请缩小范围。"
        case invalidRange = "批量范围无效，请使用递增的数字或字母范围。"
        public var errorDescription: String? { rawValue }
    }

    public static func expand(_ text: String) throws -> [String] {
        var results = [""]
        var start = text.startIndex
        for match in text.matches(of: #/\[([0-9]+|[a-zA-Z])-([0-9]+|[a-zA-Z])\]/#) {
            let first = String(match.1)
            let last = String(match.2)
            let values: [String]
            if first.utf8.allSatisfy({ (48...57).contains($0) }), last.utf8.allSatisfy({ (48...57).contains($0) }) {
                guard let lower = Int64(first), let upper = Int64(last), lower <= upper else { throw ExpansionError.invalidRange }
                guard upper - lower < 1000 else { throw ExpansionError.tooMany }
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
            guard results.count <= 1000 / values.count else { throw ExpansionError.tooMany }
            let prefix = String(text[start..<match.range.lowerBound])
            results = results.flatMap { result in values.map { result + prefix + $0 } }
            start = match.range.upperBound
        }
        return results.map { $0 + text[start...] }
    }
}

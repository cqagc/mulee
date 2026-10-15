import Foundation

public enum ExtractionPostAction: String, Sendable {
    case keep
    case trash
    case delete

    /// 只接受成功结果；失败或等待状态绝不触碰原文件。
    @discardableResult
    public func apply(to result: ExtractionResult) throws -> [URL] {
        guard result.status == .succeeded else { return [] }
        var trashed: [URL] = []
        for volume in result.originalVolumes {
            switch self {
            case .keep:
                continue
            case .delete:
                try FileManager.default.removeItem(at: volume)
            case .trash:
                var destination: NSURL?
                try FileManager.default.trashItem(at: volume, resultingItemURL: &destination)
                if let url = destination as URL? { trashed.append(url) }
            }
        }
        return trashed
    }
}

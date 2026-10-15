import Foundation
@testable import MuleeCore

struct TorrentTestRequest: Codable, Sendable {
    let id: Int
    let method: String
    let params: TorrentdValue

    var parameters: [String: TorrentdValue] {
        if case .object(let value) = params { value } else { [:] }
    }
}

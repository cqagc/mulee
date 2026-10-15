import Foundation

struct Ed2kTestDirectory {
    let url: URL

    init() throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repository.deleteLastPathComponent() }
        url = repository.appendingPathComponent("build/ed2k-tests/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func remove() throws { try FileManager.default.removeItem(at: url) }
}

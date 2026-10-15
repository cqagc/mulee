import Foundation

enum Ed2kBinaryLocator {
    static func locate(explicitURL: URL?) throws -> URL {
        let candidates = [
            explicitURL,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/amuled"),
            ProcessInfo.processInfo.environment["MULEE_AMULED"].map { URL(fileURLWithPath: $0) }
        ]
        for case let url? in candidates where FileManager.default.isExecutableFile(atPath: url.path) {
            return url.resolvingSymlinksInPath().standardizedFileURL
        }
        throw EngineError.binaryNotFound
    }
}

import Foundation

struct TorrentBinaryLocator: Sendable {
    static func locate(
        explicitURL: URL?,
        bundleURL: URL = Bundle.main.bundleURL,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        var candidates: [URL] = []
        if let explicitURL { candidates.append(explicitURL) }
        candidates.append(bundleURL.appendingPathComponent("Contents/Helpers/mulee-torrentd"))
        if let path = environment["MULEE_TORRENTD"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        guard let binary = candidates.first(where: {
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: $0.path, isDirectory: &isDirectory)
                && !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: $0.path)
        }) else { throw EngineError.binaryNotFound }
        return binary
    }
}

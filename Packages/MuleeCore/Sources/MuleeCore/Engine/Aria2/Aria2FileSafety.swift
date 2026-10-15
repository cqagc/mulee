import Foundation

struct Aria2FileSafety: Sendable {
    static func isInside(_ file: URL, directory: URL) -> Bool {
        let root = resolved(directory).pathComponents
        let path = resolved(file).pathComponents
        return path.count > root.count && path.starts(with: root)
    }

    private static func resolved(_ url: URL) -> URL {
        // Resolve existing ancestors even when the final file/control file is absent.
        url.standardizedFileURL.pathComponents.dropFirst().reduce(URL(fileURLWithPath: "/")) {
            $0.appendingPathComponent($1).resolvingSymlinksInPath()
        }
    }

    static func trashFiles(for status: Aria2RPCModels.Status) throws {
        guard let dir = status.dir, dir.hasPrefix("/") else { return }
        let directory = URL(fileURLWithPath: dir, isDirectory: true)
        for file in status.files ?? [] where file.path.hasPrefix("/") {
            let url = URL(fileURLWithPath: file.path)
            for candidate in [url, URL(fileURLWithPath: file.path + ".aria2")] {
                guard isInside(candidate, directory: directory),
                      FileManager.default.fileExists(atPath: candidate.path) else { continue }
                try FileManager.default.trashItem(at: candidate, resultingItemURL: nil)
            }
        }
    }
}

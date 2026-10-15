import Foundation

/// 下载期间文件名带任务前缀（`<任务 id>-标题.mp4`），用来判断文件归属、避免同名冲突；
/// 完成后去掉前缀，成品和同名附属文件（字幕、弹幕）一起改成用户看到的名字，重名时加序号。
enum YtDlpFinalName {
    /// 返回改名后的成品路径和所有改过名的文件名。前缀不匹配时原样返回。
    static func finalize(_ file: URL, jobID: String) throws -> (file: URL, names: [String]) {
        let prefix = jobID + "-"
        let directory = file.deletingLastPathComponent()
        let stem = file.deletingPathExtension().lastPathComponent
        guard stem.hasPrefix(prefix), stem.count > prefix.count else { return (file, []) }
        let cleanStem = String(stem.dropFirst(prefix.count))
        let sources = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0 == file.lastPathComponent || $0.hasPrefix(stem + ".") }
        let target = availableStem(cleanStem, for: sources, stem: stem, in: directory)
        var moved: [(from: URL, to: URL)] = []
        do {
            for name in sources {
                let destination = directory.appendingPathComponent(target + name.dropFirst(stem.count))
                try FileManager.default.moveItem(at: directory.appendingPathComponent(name), to: destination)
                moved.append((directory.appendingPathComponent(name), destination))
            }
        } catch {
            // 改名中途失败：把已改的改回去，保持「带前缀、可被识别为本任务文件」的一致状态。
            for item in moved.reversed() { try? FileManager.default.moveItem(at: item.to, to: item.from) }
            throw error
        }
        let finalFile = directory.appendingPathComponent(target + file.lastPathComponent.dropFirst(stem.count))
        return (finalFile, moved.map(\.to.lastPathComponent))
    }

    private static func availableStem(_ clean: String, for sources: [String], stem: String, in directory: URL) -> String {
        var candidate = clean
        var number = 2
        while sources.contains(where: { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate + name.dropFirst(stem.count)).path)
        }) {
            candidate = "\(clean) (\(number))"
            number += 1
        }
        return candidate
    }
}

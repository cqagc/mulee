import Foundation

public enum ArchiveVolumeDetector {
    public static func detect(
        filename: String,
        directoryFilenames: [String],
        expectedVolumeNames: [String]? = nil,
        expectedVolumeCount: Int? = nil
    ) -> ArchiveVolumeSet {
        let lower = filename.lowercased()
        var main = filename
        var start = 1
        var selected: [(Int, String)] = []
        var nameForIndex: (Int) -> String = { _ in filename }
        var multipart = false

        func capture(_ pattern: String, _ value: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else { return nil }
            return (1..<match.numberOfRanges).compactMap { index in
                Range(match.range(at: index), in: value).map { String(value[$0]) }
            }
        }

        let partPattern = "^(.*\\.part)([0-9]+)(\\.rar)$"
        let numericPattern = "^(.*\\.(?:7z|zip)|.+)\\.([0-9]{3})$"
        let oldPattern = "^(.*)\\.r([0-9]{2,3})$"
        let zipPattern = "^(.*)\\.z([0-9]{2,3})$"
        if let parts = capture(partPattern, filename), parts.count == 3 {
            multipart = true
            let width = parts[1].count
            nameForIndex = { parts[0] + padded($0, width: width) + parts[2] }
            for name in directoryFilenames {
                if let item = capture(partPattern, name), item.count == 3,
                   item[0].lowercased() == parts[0].lowercased(), let number = Int(item[1]), number > 0 {
                    selected.append((number, name))
                }
            }
            main = nameForIndex(1)
        } else if let parts = capture(numericPattern, filename), parts.count == 2 {
            multipart = true
            nameForIndex = { parts[0] + "." + padded($0, width: 3) }
            for name in directoryFilenames {
                if let item = capture(numericPattern, name), item.count == 2,
                   item[0].lowercased() == parts[0].lowercased(), let number = Int(item[1]), number > 0 {
                    selected.append((number, name))
                }
            }
            main = nameForIndex(1)
        } else {
            let old = capture(oldPattern, filename)
            let zip = capture(zipPattern, filename)
            let stem = String(filename.dropLast(4))
            let possibleNames = directoryFilenames + (expectedVolumeNames ?? [])
            let hasOld = possibleNames.contains { capture(oldPattern, $0)?.first?.lowercased() == stem.lowercased() }
            let hasZip = possibleNames.contains { capture(zipPattern, $0)?.first?.lowercased() == stem.lowercased() }
            if old != nil || zip != nil || (lower.hasSuffix(".rar") && hasOld) || (lower.hasSuffix(".zip") && hasZip) {
                multipart = true
                let isZip = zip != nil || (lower.hasSuffix(".zip") && hasZip)
                let base = old?.first ?? zip?.first ?? stem
                let pattern = isZip ? zipPattern : oldPattern
                start = 0
                nameForIndex = { index in
                    if index == 0 { return base + (isZip ? ".zip" : ".rar") }
                    return base + (isZip ? ".z" : ".r") + padded(isZip ? index : index - 1, width: 2)
                }
                main = nameForIndex(0)
                for name in directoryFilenames {
                    if name.lowercased() == main.lowercased() { selected.append((0, name)) }
                    if let item = capture(pattern, name), item.count == 2,
                       item[0].lowercased() == base.lowercased(), let number = Int(item[1]) {
                        selected.append((isZip ? number : number + 1, name))
                    }
                }
            }
        }
        let isArchive = multipart || [".zip", ".rar", ".7z"].contains { lower.hasSuffix($0) }
        if !multipart {
            let present = directoryFilenames.contains(filename)
            return ArchiveVolumeSet(isArchive: isArchive, isMultipart: false, mainVolume: isArchive ? filename : nil,
                                    volumes: isArchive && present ? [filename] : [],
                                    missingVolumes: isArchive && !present ? [filename] : [], completenessUnknown: false)
        }
        selected.sort { $0.0 < $1.0 }
        if let actual = selected.first(where: { $0.0 == start }) { main = actual.1 }
        let actualNames = Set(directoryFilenames.map { $0.lowercased() })
        let expectedCount = min(max(expectedVolumeCount ?? 1, 1), 100_000)
        let maximum = min(max(selected.last?.0 ?? start, expectedCount + start - 1), 100_000)
        var expected = (start...maximum).map(nameForIndex)
        if let expectedVolumeNames { expected += expectedVolumeNames }
        let missing = Array(Set(expected.filter { !actualNames.contains($0.lowercased()) })).sorted()
        return ArchiveVolumeSet(isArchive: true, isMultipart: true, mainVolume: main,
                                volumes: selected.map(\.1), missingVolumes: missing,
                                completenessUnknown: expectedVolumeNames == nil && expectedVolumeCount == nil)
    }

    private static func padded(_ number: Int, width: Int) -> String {
        let value = String(number)
        return String(repeating: "0", count: max(0, width - value.count)) + value
    }
}

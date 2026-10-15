import Testing
@testable import MuleeCore

struct ExtractionVolumeTests {
    @Test(arguments: ["star.zip", "star.ZIP", "star.rar", "star.7z"])
    func single(_ filename: String) {
        let result = ArchiveVolumeDetector.detect(filename: filename, directoryFilenames: [filename])
        #expect(result.isArchive)
        #expect(!result.isMultipart)
        #expect(result.mainVolume == filename)
        #expect(result.missingVolumes.isEmpty)
    }

    @Test("RAR5 partN 支持补零和忽略大小写，缺中间卷和末卷")
    func rarParts() {
        let result = ArchiveVolumeDetector.detect(filename: "star.part03.rar", directoryFilenames: ["star.part01.rar", "star.part03.rar", "other.part02.rar"], expectedVolumeCount: 4)
        #expect(result.mainVolume == "star.part01.rar")
        #expect(result.missingVolumes == ["star.part02.rar", "star.part04.rar"])
        #expect(!result.completenessUnknown)
        let plain = ArchiveVolumeDetector.detect(filename: "Star.Part2.RAR", directoryFilenames: ["Star.Part1.RAR", "Star.Part2.RAR"])
        #expect(plain.mainVolume == "Star.Part1.RAR")
        #expect(plain.volumes.count == 2)
        #expect(plain.completenessUnknown)
    }

    @Test("数字分卷 .7z.001、.zip.001、普通 .001")
    func numeric() {
        for base in ["star.7z", "star.zip", "star"] {
            let names = [base + ".001", base + ".003"]
            let result = ArchiveVolumeDetector.detect(filename: names[1], directoryFilenames: names)
            #expect(result.mainVolume == names[0])
            #expect(result.missingVolumes == [base + ".002"])
            #expect(result.volumes == names)
        }
    }

    @Test("旧式 RAR 主卷 .rar，续卷从 .r00 开始")
    func oldRar() {
        for name in ["star.rar", "star.r01"] {
            let result = ArchiveVolumeDetector.detect(filename: name, directoryFilenames: ["star.rar", "star.r01"])
            #expect(result.mainVolume == "star.rar")
            #expect(result.missingVolumes == ["star.r00"])
        }
        #expect(ArchiveVolumeDetector.detect(filename: "star.r00", directoryFilenames: ["star.r00"]).missingVolumes == ["star.rar"])
    }

    @Test("ZIP 主卷 .zip，续卷 .z01；预期清单发现尚未到达的所有续卷")
    func splitZip() {
        let names = ["star.zip", "star.z01", "star.z03"]
        for name in names {
            let result = ArchiveVolumeDetector.detect(filename: name, directoryFilenames: names)
            #expect(result.mainVolume == "star.zip")
            #expect(result.missingVolumes == ["star.z02"])
        }
        let result = ArchiveVolumeDetector.detect(filename: "star.zip", directoryFilenames: ["star.zip"], expectedVolumeNames: ["star.zip", "star.z01"])
        #expect(result.isMultipart)
        #expect(result.missingVolumes == ["star.z01"])
        #expect(!result.completenessUnknown)
    }

    @Test("期望清单完整时确认到齐；无清单不猜测末卷")
    func completeness() {
        let names = ["star.7z.001", "star.7z.002"]
        let known = ArchiveVolumeDetector.detect(filename: names[0], directoryFilenames: names, expectedVolumeNames: names)
        #expect(known.missingVolumes.isEmpty)
        #expect(!known.completenessUnknown)
        let unknown = ArchiveVolumeDetector.detect(filename: names[0], directoryFilenames: names)
        #expect(unknown.completenessUnknown)
        let noMain = ArchiveVolumeDetector.detect(filename: "star.z01", directoryFilenames: ["star.z01"])
        #expect(noMain.missingVolumes == ["star.zip"])
    }

    @Test("非压缩包与缺失普通文件")
    func nonArchive() {
        #expect(!ArchiveVolumeDetector.detect(filename: "star.txt", directoryFilenames: ["star.txt"]).isArchive)
        #expect(ArchiveVolumeDetector.detect(filename: "star.7z", directoryFilenames: []).missingVolumes == ["star.7z"])
        #expect(ArchiveVolumeDetector.detect(filename: "star.7z.002", directoryFilenames: ["star.7z.002"]).missingVolumes == ["star.7z.001"])
    }
}

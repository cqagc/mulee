import Foundation

public enum HTTPStreamingProgress {
    /// aria2 bitfield 高位在前；只计完整且从零开始连续的块，末块按实际大小截断。
    public static func contiguousBytes(bitfield: String, numPieces: Int, pieceLength: Int64, totalLength: Int64) -> Int64 {
        guard numPieces > 0, pieceLength > 0, totalLength > 0,
              bitfield.utf8.count >= (numPieces - 1) / 4 + 1,
              bitfield.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else { return 0 }
        var index = 0
        var completed: Int64 = 0
        for character in bitfield {
            guard let nibble = character.hexDigitValue else { return 0 }
            for mask in [8, 4, 2, 1] {
                guard index < numPieces else { return completed }
                guard nibble & mask != 0 else { return completed }
                completed += min(pieceLength, totalLength - completed)
                if completed == totalLength { return completed }
                index += 1
            }
        }
        return completed
    }
}

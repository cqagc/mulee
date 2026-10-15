import Foundation

public enum ExtractionStatus: Sendable, Equatable {
    case succeeded
    case waitingForVolumes
    case failed
}

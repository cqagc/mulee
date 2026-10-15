import Foundation
import MuleeCore
@testable import Mulee

actor ExtractionFakeExtractor: ArchiveExtracting {
    struct Invocation: Sendable {
        var archive: URL
        var destination: URL
        var rules: [UnzipRule]
        var sourceURL: URL?
        var options: ExtractionOptions
    }

    private(set) var calls: [Invocation] = []
    private(set) var maximumActive = 0
    private var active = 0
    private let suspends: Bool
    private let outcome: ExtractionOutcome
    private var releaseContinuation: AsyncStream<Void>.Continuation?

    init(suspends: Bool = false, outcome: ExtractionOutcome = ExtractionOutcome(status: .succeeded)) {
        self.suspends = suspends
        self.outcome = outcome
    }

    func extract(
        archive: URL,
        destination: URL,
        rules: [UnzipRule],
        sourceURL: URL?,
        options: ExtractionOptions,
        progress: @escaping @Sendable (Double) -> Void
    ) async -> ExtractionOutcome {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        releaseContinuation = continuation
        active += 1
        maximumActive = max(maximumActive, active)
        calls.append(Invocation(archive: archive, destination: destination, rules: rules, sourceURL: sourceURL, options: options))
        progress(0.25)
        if suspends {
            for await _ in stream { break }
        }
        active -= 1
        continuation.finish()
        if Task.isCancelled { return ExtractionOutcome(status: .failed, failure: .cancelled) }
        var result = outcome
        result.items = outcome.items.isEmpty ? [destination.appendingPathComponent("产物.txt")] : outcome.items
        return result
    }

    func release() {
        releaseContinuation?.yield(())
    }
}

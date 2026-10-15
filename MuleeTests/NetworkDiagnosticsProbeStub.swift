@testable import Mulee

actor NetworkDiagnosticsProbeStub: NetworkDiagnosticsProbing {
    let result: NetworkDiagnosticsSnapshot
    private(set) var calls = 0

    init(result: NetworkDiagnosticsSnapshot) {
        self.result = result
    }

    func probe() async -> NetworkDiagnosticsSnapshot {
        calls += 1
        return result
    }
}

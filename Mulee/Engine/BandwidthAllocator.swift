import MuleeCore

/// 只做额度计算；0 表示不限速，未活跃的引擎不参与分配。
nonisolated struct BandwidthAllocator: Sendable {
    struct Demand: Sendable {
        var rate: Int64
        var activeTasks: Int
    }

    /// 最低保障在总额不足时等比分摊；所有整数舍入都向下取整。
    static func allocate(
        limit: Int64, demand: [TaskKind: Demand], previous: [TaskKind: Int64] = [:],
        reserved: [TaskKind: Int64] = [:]
    ) -> [TaskKind: Int64] {
        let active = TaskKind.allCases.filter { demand[$0, default: Demand(rate: 0, activeTasks: 0)].activeTasks > 0 }
        guard limit > 0 else { return Dictionary(uniqueKeysWithValues: active.map { ($0, 0) }) }
        guard !active.isEmpty else { return [:] }
        let floor = min(limit / Int64(active.count), max(limit / 10, 32_000))
        var result = Dictionary(uniqueKeysWithValues: active.map { ($0, floor) })
        var remaining = limit - floor * Int64(active.count)
        // yt-dlp 的命令行额度在进程存活期间固定，不能把已承诺的额度再借出去。
        for kind in active where reserved[kind] != nil {
            let extra = min(remaining, max(0, reserved[kind, default: floor] - floor))
            result[kind, default: 0] += extra
            remaining -= extra
        }
        let flexible = active.filter { reserved[$0] == nil }
        let weights = Dictionary(uniqueKeysWithValues: flexible.map { kind in
            let measured = max(0, demand[kind]?.rate ?? 0)
            let old = previous[kind] ?? (limit / Int64(active.count))
            // 留 25% 探测空间；用满额度的引擎逐步增长，低需求引擎只保留需求与保障。
            let target = measured >= old - old / 5 ? max(measured, old) : measured
            let headroom = min(limit, target) / 4
            return (kind, max(1, min(limit - headroom, target) + headroom - floor))
        })
        let totalWeight = flexible.reduce(0.0) { $0 + Double(weights[$1, default: 1]) }
        let pool = remaining
        for kind in flexible {
            let extra = min(remaining, Int64(Double(pool) * Double(weights[kind, default: 1]) / max(1, totalWeight)))
            result[kind, default: 0] += extra
            remaining -= extra
        }
        // 余数只可能来自整数舍入；固定次序保证结果可复现。
        if let first = flexible.first { result[first, default: 0] += remaining }
        return result
    }
}

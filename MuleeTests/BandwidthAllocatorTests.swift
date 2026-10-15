import Foundation
import MuleeCore
import Testing
@testable import Mulee

@Suite struct BandwidthAllocatorTests {
    @Test func singleEngineAndUnlimited() {
        let demand: [TaskKind: BandwidthAllocator.Demand] = [.http: .init(rate: 500_000, activeTasks: 2)]
        #expect(BandwidthAllocator.allocate(limit: 1_000_000, demand: demand) == [.http: 1_000_000])
        #expect(BandwidthAllocator.allocate(limit: 0, demand: demand) == [.http: 0])
        #expect(BandwidthAllocator.allocate(limit: 1_000_000, demand: [:]).isEmpty)
    }

    @Test("总和与最低保障", arguments: [1_000, 64_000, 128_000, 1_000_000, 50_000_000])
    func floorsAndSum(limit: Int64) {
        let demand = Dictionary(uniqueKeysWithValues: TaskKind.allCases.map {
            ($0, BandwidthAllocator.Demand(rate: $0 == .http ? limit : 0, activeTasks: 1))
        })
        let allocation = BandwidthAllocator.allocate(limit: limit, demand: demand)
        let floor = min(limit / 4, max(32_000, limit / 10))
        #expect(allocation.values.reduce(0, +) <= limit)
        #expect(allocation.values.allSatisfy { $0 >= floor })
    }

    @Test func unusedQuotaGoesToBusyEngineAndIdleEngineGetsNone() throws {
        let demand: [TaskKind: BandwidthAllocator.Demand] = [
            .http: .init(rate: 500_000, activeTasks: 1),
            .bittorrent: .init(rate: 10_000, activeTasks: 1),
            .ed2k: .init(rate: 0, activeTasks: 0)
        ]
        let allocation = BandwidthAllocator.allocate(
            limit: 1_000_000, demand: demand, previous: [.http: 500_000, .bittorrent: 500_000]
        )
        #expect(try #require(allocation[.http]) > 800_000)
        #expect(try #require(allocation[.bittorrent]) >= 100_000)
        #expect(allocation[.ed2k] == nil)
        #expect(allocation.values.reduce(0, +) == 1_000_000)
    }

    @Test func saturatedEngineGrowsGradually() throws {
        let demand: [TaskKind: BandwidthAllocator.Demand] = [
            .http: .init(rate: 200_000, activeTasks: 1), .bittorrent: .init(rate: 200_000, activeTasks: 1)
        ]
        let allocation = BandwidthAllocator.allocate(
            limit: 1_000_000, demand: demand, previous: [.http: 200_000, .bittorrent: 800_000]
        )
        #expect(try #require(allocation[.http]) > 200_000)
        #expect(try #require(allocation[.http]) < 800_000)
    }

    @Test func runningVideoQuotaCannotBeBorrowed() {
        let demand: [TaskKind: BandwidthAllocator.Demand] = [
            .http: .init(rate: 800_000, activeTasks: 1), .video: .init(rate: 1_000, activeTasks: 1)
        ]
        let allocation = BandwidthAllocator.allocate(limit: 1_000_000, demand: demand, reserved: [.video: 400_000])
        #expect(allocation[.video] == 400_000)
        #expect(allocation[.http] == 600_000)
    }
}

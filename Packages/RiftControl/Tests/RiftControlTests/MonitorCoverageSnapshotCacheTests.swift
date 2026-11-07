import Foundation
import RiftControl
import RiftCore
import RiftIPC
import Testing

private actor LoadCounter {
    private(set) var count = 0
    func increment() { count += 1 }
}

private func emptySnapshot(generation: UInt64) -> RuleWorkspaceSnapshot {
    let lineage = UUID()
    let configuration = PolicyConfigurationDraft(lineageID: lineage, authorizedUID: 501,
        operationMode: .silentAllow, activeProfileID: nil, enabledLocalGroupIDs: [], rules: [])
    let tuple = PolicyTuple(lineageID: lineage, generation: generation, hash: Data(repeating: 1, count: 32))
    return RuleWorkspaceSnapshot(configuration: configuration, enforcementState: .enforced,
                                 desiredTuple: tuple, generation: generation, usage: [:])
}

@Test func monitorCoverageReusesSnapshotWithinLifetime() async throws {
    let cache = MonitorCoverageCache()
    let counter = LoadCounter()
    let start = ContinuousClock.now
    let first = try await cache.snapshot(now: start) {
        await counter.increment(); return emptySnapshot(generation: 1)
    }
    let second = try await cache.snapshot(now: start.advanced(by: .seconds(2))) {
        await counter.increment(); return emptySnapshot(generation: 2)
    }
    #expect(first?.generation == 1)
    #expect(second?.generation == 1)
    #expect(await counter.count == 1)
}

@Test func monitorCoverageReloadsSnapshotAfterLifetimeOrInvalidation() async throws {
    let cache = MonitorCoverageCache()
    let start = ContinuousClock.now
    _ = try await cache.snapshot(now: start) { emptySnapshot(generation: 1) }
    let expired = try await cache.snapshot(now: start.advanced(by: MonitorCoverageCache.snapshotLifetime)) {
        emptySnapshot(generation: 2)
    }
    #expect(expired?.generation == 2)
    await cache.invalidateSnapshot()
    let invalidated = try await cache.snapshot(now: start.advanced(by: MonitorCoverageCache.snapshotLifetime)) {
        emptySnapshot(generation: 3)
    }
    #expect(invalidated?.generation == 3)
}

@Test func monitorCoverageDoesNotCacheMissingSnapshot() async throws {
    let cache = MonitorCoverageCache()
    let start = ContinuousClock.now
    #expect(try await cache.snapshot(now: start) { nil } == nil)
    let loaded = try await cache.snapshot(now: start) { emptySnapshot(generation: 4) }
    #expect(loaded?.generation == 4)
}

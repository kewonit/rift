import AbyssCore
import AbyssIPC
import Foundation
import Testing
@testable import AbyssFilterRuntime

@Test func eventRingIsEpochBoundedAndReportsOverflow() throws {
    let ring = RuntimeEventRing()
    let signal = ActivityCounter()
    ring.installActivitySignal { signal.increment() }
    let epoch = UUID()
    ring.activate(providerEpoch: epoch)
    let flow = try fixtureFlow()
    for _ in 0...RuntimeEventRing.maximumEntries {
        ring.append(RuntimeEventSeed(
            occurredAt: Date(timeIntervalSince1970: 1),
            flow: flow,
            action: .allow,
            reason: .concreteDecision,
            policy: nil,
            notificationRequested: true
        ))
    }
    let first = ring.drain(maximumCount: 10)
    #expect(first.providerEpoch == epoch)
    #expect(first.events.count == 10)
    #expect(first.droppedCount == 1)
    #expect(first.events.first?.sequence == 2)
    #expect(first.events.first?.notificationRequested == true)
    #expect(signal.value == RuntimeEventRing.maximumEntries + 1)
    ring.deactivate(providerEpoch: epoch)
    ring.append(RuntimeEventSeed(
        occurredAt: Date(), flow: flow, action: .deny, reason: .noActivePolicy, policy: nil
    ))
    #expect(ring.drain(maximumCount: 10).events.count == 10)
}

@Test func eventRingRetainsDecisionsAheadOfStatisticsAndCloseEvents() throws {
    let ring = RuntimeEventRing()
    let epoch = UUID()
    let flow = try fixtureFlow()
    ring.activate(providerEpoch: epoch)
    ring.append(fixtureSeed(kind: .decision, flow: flow))
    for _ in 1..<RuntimeEventRing.maximumEntries {
        ring.append(fixtureSeed(kind: .statistics, flow: flow))
    }

    ring.append(fixtureSeed(kind: .statistics, flow: flow))
    ring.append(fixtureSeed(kind: .closed, flow: flow))
    ring.append(fixtureSeed(kind: .decision, flow: flow))
    let batch = ring.drain(maximumCount: RuntimeEventRing.maximumEntries * 2)

    #expect(batch.events.count == RuntimeEventRing.maximumEntries)
    #expect(batch.droppedCount == 3)
    #expect(batch.events.filter { $0.kind == .decision }.map(\.sequence) == [
        1, UInt64(RuntimeEventRing.maximumEntries + 3),
    ])
    #expect(batch.events.filter { $0.kind == .closed }.count == 1)
}

@Test func reactivatingSameEpochPreservesBacklogAndSequence() throws {
    let ring = RuntimeEventRing()
    let signal = ActivityCounter()
    ring.installActivitySignal { signal.increment() }
    let epoch = UUID()
    let flow = try fixtureFlow()
    ring.activate(providerEpoch: epoch)
    ring.append(fixtureSeed(kind: .decision, flow: flow))

    ring.activate(providerEpoch: epoch)
    let retained = ring.drain(maximumCount: 10)
    #expect(retained.events.map(\.sequence) == [1])
    #expect(retained.droppedCount == 0)
    #expect(signal.value == 2)

    ring.append(fixtureSeed(kind: .decision, flow: flow))
    #expect(ring.drain(maximumCount: 10).events.map(\.sequence) == [2])
}

@Test func epochChangePreservesBacklogAndReportsCoverageLoss() throws {
    let ring = RuntimeEventRing()
    let signal = ActivityCounter()
    ring.installActivitySignal { signal.increment() }
    let firstEpoch = UUID()
    let secondEpoch = UUID()
    let flow = try fixtureFlow()
    ring.activate(providerEpoch: firstEpoch)
    ring.append(fixtureSeed(kind: .decision, flow: flow))

    ring.activate(providerEpoch: secondEpoch)
    let transition = ring.drain(maximumCount: 10)
    #expect(transition.providerEpoch == secondEpoch)
    #expect(transition.events.map(\.providerEpoch) == [firstEpoch])
    #expect(transition.events.map(\.sequence) == [1])
    #expect(transition.droppedCount == 1)
    #expect(signal.value == 2)

    ring.append(fixtureSeed(kind: .decision, flow: flow))
    let current = ring.drain(maximumCount: 10)
    #expect(current.events.map(\.providerEpoch) == [secondEpoch])
    #expect(current.events.map(\.sequence) == [1])
    #expect(current.droppedCount == 1)
}

@Test func droppedCountIsMonotonicAndSaturating() throws {
    let ring = RuntimeEventRing()
    let firstEpoch = UUID()
    let flow = try fixtureFlow()
    ring.activate(providerEpoch: firstEpoch)
    for _ in 0..<RuntimeEventRing.maximumEntries {
        ring.append(fixtureSeed(kind: .statistics, flow: flow))
    }
    ring.append(fixtureSeed(kind: .statistics, flow: flow))
    #expect(ring.drain(maximumCount: 0).droppedCount == 1)

    _ = ring.drain(maximumCount: 1)
    ring.append(fixtureSeed(kind: .statistics, flow: flow))
    #expect(ring.drain(maximumCount: 0).droppedCount == 1)
    ring.append(fixtureSeed(kind: .statistics, flow: flow))
    #expect(ring.drain(maximumCount: 0).droppedCount == 2)

    ring.activate(providerEpoch: UUID())
    #expect(ring.drain(maximumCount: 0).droppedCount == 3)
    #expect(RuntimeEventRing.saturatingAdd(.max - 1, 1) == .max)
    #expect(RuntimeEventRing.saturatingAdd(.max - 1, 2) == .max)
    #expect(RuntimeEventRing.saturatingAdd(.max, 1) == .max)
}

@Test func eventRingRemainsStrictlyBoundedWhenOnlyDecisionsExist() throws {
    let ring = RuntimeEventRing()
    ring.activate(providerEpoch: UUID())
    let flow = try fixtureFlow()
    let overflow = 128
    for _ in 0..<(RuntimeEventRing.maximumEntries + overflow) {
        ring.append(fixtureSeed(kind: .decision, flow: flow))
    }
    ring.append(fixtureSeed(kind: .statistics, flow: flow))

    let batch = ring.drain(maximumCount: RuntimeEventRing.maximumEntries * 2)
    #expect(batch.events.count == RuntimeEventRing.maximumEntries)
    #expect(batch.events.allSatisfy { $0.kind == .decision })
    #expect(batch.droppedCount == UInt64(overflow + 1))
    #expect(batch.events.first?.sequence == UInt64(overflow + 1))
}

@Test func ephemeralNotificationQueueIsBoundedSignaledAndExpires() throws {
    let queue = EphemeralNotificationQueue()
    let signal = ActivityCounter()
    queue.installActivitySignal { signal.increment() }
    let flow = try fixtureFlow()
    let start = Date(timeIntervalSince1970: 1_000)
    for index in 0..<300 {
        queue.append(EphemeralNotificationEvent(
            occurredAt: start.addingTimeInterval(Double(index) / 100),
            flow: flow,
            action: .allow,
            reason: .concreteDecision
        ))
    }
    var drained = 0
    for _ in 0..<4 { drained += queue.drain(now: start.addingTimeInterval(3)).count }
    #expect(drained == 256)
    #expect(signal.value == 300)
    queue.append(EphemeralNotificationEvent(
        occurredAt: start,
        flow: flow,
        action: .deny,
        reason: .concreteDecision
    ))
    #expect(queue.drain(now: start.addingTimeInterval(31)).isEmpty)
}

private final class ActivityCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private func fixtureSeed(
    kind: RuntimeEventKind,
    flow: FlowDescriptor
) -> RuntimeEventSeed {
    RuntimeEventSeed(
        kind: kind,
        occurredAt: Date(timeIntervalSince1970: 1),
        flow: flow,
        action: .allow,
        reason: .concreteDecision,
        policy: nil
    )
}

private func fixtureFlow() throws -> FlowDescriptor {
    FlowDescriptor(
        flowID: UUID(),
        observedAt: Date(timeIntervalSince1970: 1),
        sourceAppIdentity: nil,
        sourceProcessIdentity: nil,
        owner: .user(uid: 501),
        direction: .outgoing,
        transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("203.0.113.5"),
            port: 443,
            hostname: nil,
            hostnameCoverage: .absent,
            classes: [],
            interfaceSnapshotGeneration: 0
        ),
        observedHostname: nil,
        metadataConfidence: [.endpoint]
    )
}

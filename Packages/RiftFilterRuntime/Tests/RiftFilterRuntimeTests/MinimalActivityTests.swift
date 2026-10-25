import Foundation
import RiftCore
import RiftIPC
import Testing
@testable import RiftFilterRuntime

@Test func disabledActivityCreatesNoEventsButSignalsDenyAttention() {
    let ring = RuntimeEventRing()
    let activity = MinimalSignalCounter()
    let attention = MinimalSignalCounter()
    ring.installActivitySignal { activity.increment() }
    ring.installAttentionSignal { attention.increment() }
    ring.configure(ActivitySubscription(mode: .off))
    let epoch = UUID()
    ring.activate(providerEpoch: epoch)
    let flow = minimalFlow(at: Date())
    for _ in 0..<1_000 { ring.append(minimalSeed(flow)) }
    ring.recordAnonymousLoss(10)
    ring.noteDeny(at: flow.observedAt)
    #expect(ring.drain().events.isEmpty)
    #expect(ring.drain().droppedCount == 0)
    #expect(ring.recentSnapshot().events.isEmpty)
    #expect(!ring.shouldReport(flowID: flow.flowID))
    #expect(activity.value == 0)
    #expect(attention.value == 1)
    #expect(ring.takeRecentDeny() == flow.observedAt)
    #expect(ring.takeRecentDeny() == nil)
}

@Test(arguments: [5, 10, 50]) func recentActivityIsBoundedAndExpires(capacity: Int) {
    let ring = RuntimeEventRing()
    let start = Date(timeIntervalSince1970: 10_000)
    let subscription = ActivitySubscription(mode: .recent, maximumRecentConnections: capacity)
    ring.configure(subscription)
    ring.activate(providerEpoch: UUID())
    var last: FlowDescriptor!
    for index in 0..<500 {
        last = minimalFlow(at: start.addingTimeInterval(Double(index) / 10))
        ring.append(minimalSeed(last))
    }
    let snapshot = ring.recentSnapshot(now: start.addingTimeInterval(50))
    #expect(snapshot.subscriptionID == subscription.id)
    #expect(snapshot.events.count == capacity)
    #expect(snapshot.isTruncated)
    #expect(ring.drain().events.isEmpty)
    #expect(ring.drain().droppedCount == 0)
    #expect(ring.shouldReport(flowID: last.flowID))
    let expired = ring.recentSnapshot(now: start.addingTimeInterval(350))
    #expect(expired.events.isEmpty)
    #expect(expired.nextExpiry == nil)
    #expect(!ring.shouldReport(flowID: last.flowID))
}

@Test func recentActivityMergesReorderedClosureAndMonotonicByteCounters() {
    let ring = RuntimeEventRing()
    let start = Date(timeIntervalSince1970: 10_000)
    let flow = minimalFlow(at: start)
    ring.configure(ActivitySubscription(mode: .recent, maximumRecentConnections: 5))
    ring.activate(providerEpoch: UUID())
    ring.append(minimalSeed(flow, kind: .closed, at: start.addingTimeInterval(2), bytes: 10))
    ring.append(minimalSeed(flow))
    ring.append(minimalSeed(flow, kind: .statistics, at: start.addingTimeInterval(3), bytes: 20))
    ring.append(minimalSeed(flow, kind: .statistics, at: start.addingTimeInterval(1), bytes: 5))
    ring.append(minimalSeed(flow, kind: .closed, at: start.addingTimeInterval(1), bytes: 5))
    let values = ring.recentSnapshot(now: start.addingTimeInterval(4)).events
    #expect(values.count == 2)
    #expect(values[0].kind == .decision)
    #expect(values[1].kind == .closed)
    #expect(values[1].occurredAt == start.addingTimeInterval(2))
    #expect(values[1].bytesInbound == 20)
    #expect(values[1].bytesOutbound == 20)
}

@Test func stoppingOrReplacingSubscriptionReleasesRecentAndLifecycleBuffers() {
    let ring = RuntimeEventRing()
    let tracker = VisibleFlowReportTracker()
    ring.installCaptureChangeHandler { _ = tracker.takeAll() }
    ring.installRecentExpiryHandler { tracker.remove(flowIDs: $0) }
    let start = Date(timeIntervalSince1970: 10_000)
    ring.configure(ActivitySubscription(mode: .recent, maximumRecentConnections: 5))
    ring.activate(providerEpoch: UUID())
    for index in 0..<8 {
        let flow = minimalFlow(at: start.addingTimeInterval(Double(index)))
        let seed = minimalSeed(flow)
        ring.append(seed)
        tracker.retainRecent(flowID: flow.flowID, decision: seed, maximum: 5, now: flow.observedAt)
    }
    #expect(ring.recentSnapshot(now: start.addingTimeInterval(8)).events.count == 5)
    _ = ring.recentSnapshot(now: start.addingTimeInterval(308))
    #expect(tracker.takeAll().isEmpty)
    let flow = minimalFlow(at: start.addingTimeInterval(400))
    ring.append(minimalSeed(flow))
    tracker.retainRecent(flowID: flow.flowID, decision: minimalSeed(flow), maximum: 5, now: flow.observedAt)
    ring.configure(ActivitySubscription(mode: .off))
    #expect(tracker.takeAll().isEmpty)
    #expect(ring.recentSnapshot(now: flow.observedAt).events.isEmpty)
}

@Test func providerRestartCannotReplayRecentActivity() {
    let ring = RuntimeEventRing()
    let start = Date(timeIntervalSince1970: 10_000)
    ring.configure(ActivitySubscription(mode: .recent, maximumRecentConnections: 5))
    let oldEpoch = UUID()
    ring.activate(providerEpoch: oldEpoch)
    ring.append(minimalSeed(minimalFlow(at: start)))
    ring.deactivate(providerEpoch: oldEpoch)
    let newEpoch = UUID()
    ring.activate(providerEpoch: newEpoch)
    let snapshot = ring.recentSnapshot(now: start)
    #expect(snapshot.providerEpoch == newEpoch)
    #expect(snapshot.events.isEmpty)
    #expect(ring.drain().droppedCount == 0)
}

@Test func persistentSubscriptionRenewalKeepsUndrainedEventsAndReports() {
    let ring = RuntimeEventRing()
    let tracker = VisibleFlowReportTracker()
    ring.configure(ActivitySubscription(mode: .persistent))
    ring.installCaptureChangeHandler { _ = tracker.takeAll() }
    ring.activate(providerEpoch: UUID())
    let flow = minimalFlow(at: Date())
    let seed = minimalSeed(flow)
    ring.append(seed)
    #expect(tracker.retain(flowID: flow.flowID, decision: seed) == .retained)

    ring.configure(ActivitySubscription(mode: .persistent, notifyImplicitDecisions: true))

    let batch = ring.drain()
    #expect(batch.events.count == 1)
    #expect(batch.events.first?.flow.flowID == flow.flowID)
    #expect(batch.droppedCount == 0)
    #expect(tracker.takeAll().count == 1)
}

@Test func promptResolutionSignalsIndependentlyOfActivityRecording() throws {
    let queue = PromptQueue()
    let signal = MinimalSignalCounter()
    queue.installActivitySignal { signal.increment() }
    let lease = UUID(), epoch = UUID(), lineage = UUID()
    queue.activate(controllerLeaseID: lease, providerEpoch: epoch)
    let seed = PromptSeed(lineageID: lineage, generation: 1, flow: minimalFlow(at: Date()),
                          winningRuleID: nil, affectingRuleIDs: [])
    let nonce = try queue.enqueue(seed, deadline: Date().addingTimeInterval(30)) { _ in }
    #expect(try queue.activeNonces(controllerLeaseID: lease) == [nonce])
    let delivered = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(try queue.drain(controllerLeaseID: lease).isEmpty)
    try queue.redeliverActive(controllerLeaseID: lease)
    let resynced = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(resynced.nonce == delivered.nonce)
    #expect(resynced.deadline == delivered.deadline)
    try queue.answer(PromptAnswer(nonce: nonce, providerEpoch: epoch, lineageID: lineage,
                                  generation: 1, action: .allow), controllerLeaseID: lease)
    #expect(signal.value == 2)
    #expect(try queue.activeNonces(controllerLeaseID: lease).isEmpty)
    let expiring = try queue.enqueue(seed, deadline: Date().addingTimeInterval(8)) { _ in }
    #expect(queue.expire(expiring, now: Date().addingTimeInterval(9)))
    #expect(signal.value == 4)
    let cancelled = try queue.enqueue(seed, deadline: Date().addingTimeInterval(8)) { _ in }
    queue.cancel(cancelled)
    #expect(signal.value == 6)
}

private func minimalFlow(at date: Date) -> FlowDescriptor {
    FlowDescriptor(flowID: UUID(), observedAt: date, sourceAppIdentity: nil,
                   sourceProcessIdentity: nil, owner: .user(uid: 501), direction: .outgoing,
                   transportProtocol: .tcp, localEndpoint: nil, remoteEndpoint: nil,
                   observedHostname: nil, metadataConfidence: [])
}

private func minimalSeed(_ flow: FlowDescriptor, kind: RuntimeEventKind = .decision,
                         at date: Date? = nil, bytes: UInt64? = nil) -> RuntimeEventSeed {
    RuntimeEventSeed(kind: kind, occurredAt: date ?? flow.observedAt, flow: flow, action: .allow,
                     reason: .concreteDecision, policy: nil, bytesInbound: bytes, bytesOutbound: bytes,
                     flowEndReason: kind == .closed ? .networkExtensionReport : nil)
}

private final class MinimalSignalCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

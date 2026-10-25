import RiftCore
import RiftIPC
import Foundation
import Testing
@testable import RiftFilterRuntime

@Test func visibleReportTrackerReturnsOnlyRegisteredAllowedFlows() throws {
    let tracker = VisibleFlowReportTracker(maximumEntries: 2)
    let allowedID = UUID()
    let deniedID = UUID()
    let allowed = try reportSeed(action: .allow)
    let denied = try reportSeed(action: .deny)

    #expect(tracker.retain(flowID: allowedID, decision: allowed) == .retained)
    #expect(tracker.retain(flowID: deniedID, decision: denied) == .notTrackable)
    #expect(tracker.decision(flowID: UUID()) == nil)
    #expect(tracker.decision(flowID: deniedID) == nil)
    let returned = tracker.take(flowID: allowedID)
    #expect(returned?.action == allowed.action)
    #expect(returned?.flow == allowed.flow)
    #expect(tracker.take(flowID: allowedID) == nil)
}

@Test func visibleReportTrackerIsBoundedAndDrainsOnlyTrackedFlows() throws {
    let tracker = VisibleFlowReportTracker(maximumEntries: 2)
    let seed = try reportSeed(action: .allow)
    let first = UUID()
    let second = UUID()

    #expect(tracker.retain(flowID: first, decision: seed) == .retained)
    #expect(tracker.retain(flowID: first, decision: seed) == .retained)
    #expect(tracker.retain(flowID: second, decision: seed) == .retained)
    #expect(tracker.retain(flowID: UUID(), decision: seed) == .capacityExceeded)
    #expect(tracker.takeAll().count == 2)
    #expect(tracker.takeAll().isEmpty)
}

@Test func anonymousReportLossAdvancesOnlyTheCoverageCounter() throws {
    let ring = RuntimeEventRing()
    let epoch = UUID()
    ring.activate(providerEpoch: epoch)
    ring.recordAnonymousLoss()

    let batch = ring.drain(maximumCount: 10)
    #expect(batch.providerEpoch == epoch)
    #expect(batch.events.isEmpty)
    #expect(batch.droppedCount == 1)
}

private func reportSeed(action: FilterAction) throws -> RuntimeEventSeed {
    RuntimeEventSeed(
        occurredAt: Date(timeIntervalSince1970: 1),
        flow: try fixtureReportFlow(),
        action: action,
        reason: .concreteDecision,
        policy: nil
    )
}

private func fixtureReportFlow() throws -> FlowDescriptor {
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
            address: try IPAddress("203.0.113.8"),
            port: 443,
            hostname: nil,
            hostnameCoverage: .absent,
            classes: [],
            interfaceSnapshotGeneration: 0
        ),
        observedHostname: try DomainName("example.test"),
        metadataConfidence: [.endpoint, .observedHostname]
    )
}

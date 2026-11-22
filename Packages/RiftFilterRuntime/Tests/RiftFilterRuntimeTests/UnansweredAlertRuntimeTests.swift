import RiftCore
import RiftIPC
import Foundation
import Testing
@testable import RiftFilterRuntime

private let observedAt = Date(timeIntervalSince1970: 1_700_000_000)

private func flow(_ transport: TransportProtocol = .tcp) -> FlowDescriptor {
    FlowDescriptor(
        flowID: UUID(), observedAt: observedAt, sourceAppIdentity: nil, sourceProcessIdentity: nil,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: transport,
        localEndpoint: nil, remoteEndpoint: nil, observedHostname: nil, metadataConfidence: []
    )
}

private func runtimePolicy(_ alerts: UnansweredAlertPolicy?) throws -> RuntimePolicy {
    let lineage = UUID()
    let payload = try CompiledPolicyPayload(
        lineageID: lineage, generation: 1, authorizedUID: 501, createdAt: observedAt,
        operationMode: .alert, activeProfileID: nil, enabledLocalGroupIDs: [], rules: [],
        unansweredAlerts: alerts
    )
    let artifact = try PolicyArtifact.compile(payload)
    return RuntimePolicy(recovered: RecoveredPolicy(
        tuple: PolicyTuple(lineageID: lineage, generation: 1, hash: artifact.hash),
        artifact: artifact, payload: payload, recoveredAfterLostAcknowledgement: false
    ))
}

@Test func aPolicyWithoutUnansweredAlertsAllowsAtTheDeadlineEarlierBuildsUsed() throws {
    let policy = try runtimePolicy(nil)
    #expect(policy.unansweredAction == .allow)
    let late = observedAt.addingTimeInterval(20)
    #expect(policy.promptDeadline(for: flow(.tcp), askedAt: late) == observedAt.addingTimeInterval(30))
    #expect(policy.promptDeadline(for: flow(.udp), askedAt: late) == observedAt.addingTimeInterval(8))
}

@Test func aPolicyThatBlocksUnansweredAlertsDeniesAfterItsOwnWait() throws {
    let policy = try runtimePolicy(UnansweredAlertPolicy(action: .deny, waitSeconds: 90))
    #expect(policy.unansweredAction == .deny)
    #expect(policy.promptDeadline(for: flow(.tcp), askedAt: observedAt)
        == observedAt.addingTimeInterval(90))
    #expect(policy.promptDeadline(for: flow(.udp), askedAt: observedAt)
        == observedAt.addingTimeInterval(8))
}

@Test func aConnectionThatNeedsAnAnswerNobodyCanGiveFollowsThePolicy() throws {
    let fixture = IdentityAdmissionAskFixture()
    let ask = try fixture.askDecision()
    #expect(ask.filter.action == .ask)
    #expect(IdentityResolutionAdmissionPolicy.fallback(for: ask).action == .allow)
    #expect(IdentityResolutionAdmissionPolicy.fallback(
        for: ask, unansweredAction: .allow
    ).action == .allow)
    let blocked = IdentityResolutionAdmissionPolicy.fallback(for: ask, unansweredAction: .deny)
    #expect(blocked.action == .deny)
    #expect(blocked.reason == .promptUnavailableFallback)
    // Ask is never a verdict, whatever is passed in.
    #expect(IdentityResolutionAdmissionPolicy.fallback(
        for: ask, unansweredAction: .ask
    ).action == .allow)
}

@Test func theUnansweredActionNeverOverridesARuleOrModeThatAlreadyDecided() throws {
    let fixture = IdentityAdmissionAskFixture()
    let allow = try fixture.decision(mode: .silentAllow)
    let deny = try fixture.decision(mode: .silentDeny)
    #expect(IdentityResolutionAdmissionPolicy.fallback(
        for: allow, unansweredAction: .deny
    ).action == .allow)
    #expect(IdentityResolutionAdmissionPolicy.fallback(
        for: deny, unansweredAction: .allow
    ).action == .deny)
}

@Test func promptsReachAnOlderAppWithoutFieldsItWouldRefuse() throws {
    let queue = PromptQueue()
    let lease = UUID()
    queue.activate(controllerLeaseID: lease, providerEpoch: UUID())
    let seed = PromptSeed(
        lineageID: UUID(), generation: 2, flow: flow(), winningRuleID: nil,
        affectingRuleIDs: [], unansweredAction: .deny
    )
    let deadline = Date().addingTimeInterval(60)
    let nonce = try queue.enqueue(seed, deadline: deadline) { _ in }

    // Until the controller says which protocol it speaks, it gets the shape
    // every app can decode.
    let unknown = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(unknown.unansweredAction == nil)
    #expect(unknown.deadline == deadline)

    queue.setControllerProtocol(.internationalNames, controllerLeaseID: lease)
    try queue.redeliverActive(controllerLeaseID: lease)
    let older = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(older.nonce == nonce)
    #expect(older.unansweredAction == nil)
    let olderBytes = try SecureIPCCodec.encode(older)
    #expect(!String(decoding: olderBytes, as: UTF8.self).contains("unansweredAction"))
    #expect(try SecureIPCCodec.decode(PromptRequest.self, from: olderBytes).nonce == nonce)

    queue.setControllerProtocol(.extendedPolicy, controllerLeaseID: lease)
    try queue.redeliverActive(controllerLeaseID: lease)
    let current = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(current.unansweredAction == .deny)

    // Another controller's protocol says nothing about this one.
    let nextLease = UUID()
    queue.activate(controllerLeaseID: nextLease, providerEpoch: UUID())
    _ = try queue.enqueue(seed, deadline: deadline) { _ in }
    #expect(try #require(queue.drain(controllerLeaseID: nextLease).first).unansweredAction == nil)
}

@Test func aJoinedCohortKeepsTheUnansweredAction() throws {
    let queue = PromptQueue()
    let lease = UUID()
    queue.activate(controllerLeaseID: lease, providerEpoch: UUID())
    queue.setControllerProtocol(.extendedPolicy, controllerLeaseID: lease)
    let nonce = try queue.enqueue(
        PromptSeed(
            lineageID: UUID(), generation: 2, flow: flow(), winningRuleID: nil,
            affectingRuleIDs: [], unansweredAction: .deny
        ),
        deadline: Date().addingTimeInterval(60)
    ) { _ in }
    _ = try queue.drain(controllerLeaseID: lease)
    #expect(queue.updateCohort(nonce, deadline: Date().addingTimeInterval(90), count: 2))
    let updated = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(updated.cohortCount == 2)
    #expect(updated.unansweredAction == .deny)
}

@Test func processDetailsReachOnlyAnAppThatCanDecodeThem() throws {
    let processes = try #require(FlowProcessDetails(
        process: ObservedProcess(processID: 812, executablePath: "/usr/local/bin/sync-tool"),
        app: nil
    ))
    let ring = RuntimeEventRing()
    ring.activate(providerEpoch: UUID())
    func appendDecision() {
        ring.append(RuntimeEventSeed(
            occurredAt: observedAt, flow: flow(), action: .allow, reason: .concreteDecision,
            policy: nil, processes: processes
        ))
    }

    // An app that hasn't said which protocol it speaks gets the oldest shape.
    appendDecision()
    #expect(ring.drain().events.map(\.processes) == [nil])

    ring.setControllerProtocol(.extendedPolicy)
    appendDecision()
    #expect(ring.drain().events.map(\.processes) == [processes])

    // Events still queued when an older app takes over lose the new field.
    appendDecision()
    ring.setControllerProtocol(.internationalNames)
    let older = ring.drain().events
    #expect(older.map(\.processes) == [nil])
    #expect(try SecureIPCCodec.decode(
        [RuntimeEvent].self, from: SecureIPCCodec.encode(older)
    ).count == 1)

    // The recent-activity snapshot follows the same rule and keeps the
    // details through a merge with byte counts.
    ring.configure(ActivitySubscription(mode: .recent, maximumRecentConnections: 5))
    let recentFlow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(), sourceAppIdentity: nil, sourceProcessIdentity: nil,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp,
        localEndpoint: nil, remoteEndpoint: nil, observedHostname: nil, metadataConfidence: []
    )
    ring.append(RuntimeEventSeed(
        occurredAt: Date(), flow: recentFlow, action: .allow, reason: .concreteDecision,
        policy: nil, processes: processes
    ))
    ring.append(RuntimeEventSeed(
        kind: .statistics, occurredAt: Date(), flow: recentFlow, action: .allow,
        reason: .concreteDecision, policy: nil, bytesInbound: 4, bytesOutbound: 2
    ))
    #expect(ring.recentSnapshot().events.allSatisfy { $0.processes == nil })
    ring.setControllerProtocol(.extendedPolicy)
    let recent = ring.recentSnapshot().events
    #expect(recent.first { $0.kind == .decision }?.processes == processes)
    #expect(recent.first { $0.kind == .statistics }?.bytesInbound == 4)
}

private struct IdentityAdmissionAskFixture {
    let lineageID = UUID()

    func askDecision() throws -> Decision { try decision(mode: .alert) }

    func decision(mode: OperationMode) throws -> Decision {
        let payload = try CompiledPolicyPayload(
            lineageID: lineageID, generation: 1, authorizedUID: 501, createdAt: observedAt,
            operationMode: mode, activeProfileID: nil, enabledLocalGroupIDs: [], rules: []
        )
        let artifact = try PolicyArtifact.compile(payload)
        return RuntimePolicy(recovered: RecoveredPolicy(
            tuple: PolicyTuple(lineageID: lineageID, generation: 1, hash: artifact.hash),
            artifact: artifact, payload: payload, recoveredAfterLostAcknowledgement: false
        )).decision(for: flow(), now: observedAt)
    }
}

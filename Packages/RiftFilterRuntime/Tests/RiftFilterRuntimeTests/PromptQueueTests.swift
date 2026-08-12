import RiftCore
import RiftIPC
import Foundation
import Testing
@testable import RiftFilterRuntime

@Test func promptQueueBindsLeaseEpochNonceAndGeneration() throws {
    let queue = PromptQueue()
    let lease = UUID()
    let epoch = UUID()
    let lineage = UUID()
    queue.activate(controllerLeaseID: lease, providerEpoch: epoch)
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(), sourceAppIdentity: nil, sourceProcessIdentity: nil,
        owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp,
        localEndpoint: nil, remoteEndpoint: nil, observedHostname: nil, metadataConfidence: []
    )
    let recorded = LockedResolutions()
    let deadline = Date().addingTimeInterval(30)
    _ = try queue.enqueue(
        PromptSeed(
            lineageID: lineage, generation: 9, flow: flow,
            winningRuleID: nil, affectingRuleIDs: []
        ),
        deadline: deadline
    ) { recorded.append($0) }
    let prompt = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(prompt.deadline == deadline)
    #expect(throws: PromptQueueError.staleAnswer) {
        try queue.answer(
            PromptAnswer(
                nonce: prompt.nonce, providerEpoch: epoch, lineageID: lineage,
                generation: 8, action: .deny
            ),
            controllerLeaseID: lease
        )
    }
    try queue.answer(
        PromptAnswer(
            nonce: prompt.nonce, providerEpoch: epoch, lineageID: lineage,
            generation: 9, action: .deny
        ),
        controllerLeaseID: lease
    )
    #expect(!queue.expire(prompt.nonce, now: deadline))
    #expect(recorded.load() == [.answered(.deny)])
}

@Test func promptQueueDeadlineWinsExactlyOnce() throws {
    let queue = PromptQueue()
    let lease = UUID()
    let epoch = UUID()
    let lineage = UUID()
    queue.activate(controllerLeaseID: lease, providerEpoch: epoch)
    let recorded = LockedResolutions()
    let deadline = Date().addingTimeInterval(30)
    let nonce = try queue.enqueue(
        try promptSeed(lineage: lineage),
        deadline: deadline
    ) { recorded.append($0) }

    #expect(queue.expire(nonce, now: deadline))
    #expect(!queue.expire(nonce, now: deadline))
    #expect(throws: PromptQueueError.staleAnswer) {
        try queue.answer(
            PromptAnswer(
                nonce: nonce, providerEpoch: epoch, lineageID: lineage,
                generation: 9, action: .deny
            ),
            controllerLeaseID: lease
        )
    }
    #expect(recorded.load() == [.deadlineFallback])
}

@Test func promptQueueRedeliversUpdatedCohortCountAndEarliestDeadline() throws {
    let queue = PromptQueue()
    let lease = UUID()
    queue.activate(controllerLeaseID: lease, providerEpoch: UUID())
    let recorded = LockedResolutions()
    let later = Date().addingTimeInterval(30)
    let earlier = later.addingTimeInterval(-10)
    let nonce = try queue.enqueue(
        try promptSeed(lineage: UUID()),
        deadline: later
    ) { recorded.append($0) }

    let initial = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(initial.deadline == later)
    #expect(initial.cohortCount == 1)
    #expect(queue.updateCohort(nonce, deadline: earlier, count: 1))
    let deadlineRefresh = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(deadlineRefresh.nonce == nonce)
    #expect(deadlineRefresh.deadline == earlier)
    #expect(deadlineRefresh.cohortCount == 1)
    #expect(queue.updateCohort(nonce, deadline: earlier, count: 3))
    let countRefresh = try #require(queue.drain(controllerLeaseID: lease).first)
    #expect(countRefresh.nonce == nonce)
    #expect(countRefresh.deadline == earlier)
    #expect(countRefresh.cohortCount == 3)
    #expect(try queue.drain(controllerLeaseID: lease).isEmpty)
    #expect(queue.expire(nonce, now: earlier))
    #expect(recorded.load() == [.deadlineFallback])
}

@Test func cancelledPromptCannotResolveAfterPolicyReplacement() throws {
    let queue = PromptQueue()
    let lease = UUID()
    let epoch = UUID()
    let lineage = UUID()
    queue.activate(controllerLeaseID: lease, providerEpoch: epoch)
    let recorded = LockedResolutions()
    let deadline = Date().addingTimeInterval(30)
    let seed = try promptSeed(lineage: lineage)
    let oldNonce = try queue.enqueue(seed, deadline: deadline) { recorded.append($0) }
    queue.cancel(oldNonce)
    let newNonce = try queue.enqueue(seed, deadline: deadline) { recorded.append($0) }

    #expect(!queue.expire(oldNonce, now: deadline))
    #expect(throws: PromptQueueError.staleAnswer) {
        try queue.answer(
            PromptAnswer(
                nonce: oldNonce, providerEpoch: epoch, lineageID: lineage,
                generation: 9, action: .deny
            ),
            controllerLeaseID: lease
        )
    }
    try queue.answer(
        PromptAnswer(
            nonce: newNonce, providerEpoch: epoch, lineageID: lineage,
            generation: 9, action: .allow
        ),
        controllerLeaseID: lease
    )
    #expect(recorded.load() == [.answered(.allow)])
}

@Test func promptQueueDeactivationFallsBackExactlyOnce() throws {
    let queue = PromptQueue()
    let lease = UUID()
    queue.activate(controllerLeaseID: lease, providerEpoch: UUID())
    let recorded = LockedResolutions()
    let deadline = Date().addingTimeInterval(30)
    let nonce = try queue.enqueue(
        try promptSeed(lineage: UUID()),
        deadline: deadline
    ) { recorded.append($0) }

    queue.deactivate(controllerLeaseID: lease)
    #expect(!queue.expire(nonce, now: deadline))
    #expect(recorded.load() == [.unavailableFallback])
}

@Test func promptCohortKeyPreservesInternalIdentityAndDestination() throws {
    let lineage = UUID()
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAMID", signingIdentifier: "com.example.first")
    )
    let sameIdentity = try promptFlow(appIdentity: identity, address: "203.0.113.1")
    let sameCohort = try promptFlow(appIdentity: identity, address: "203.0.113.1")
    let otherIdentity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAMID", signingIdentifier: "com.example.second")
    )

    #expect(
        PromptCohortKey(lineageID: lineage, generation: 9, flow: sameIdentity)
            == PromptCohortKey(lineageID: lineage, generation: 9, flow: sameCohort)
    )
    #expect(
        PromptCohortKey(lineageID: lineage, generation: 9, flow: sameIdentity)
            != PromptCohortKey(
                lineageID: lineage,
                generation: 9,
                flow: try promptFlow(appIdentity: otherIdentity, address: "203.0.113.1")
            )
    )
    #expect(
        PromptCohortKey(lineageID: lineage, generation: 9, flow: sameIdentity)
            != PromptCohortKey(
                lineageID: lineage,
                generation: 9,
                flow: try promptFlow(appIdentity: identity, address: "203.0.113.2")
            )
    )
}

private func promptSeed(lineage: UUID) throws -> PromptSeed {
    PromptSeed(
        lineageID: lineage,
        generation: 9,
        flow: try promptFlow(appIdentity: nil, address: "203.0.113.1"),
        winningRuleID: nil,
        affectingRuleIDs: []
    )
}

private func promptFlow(appIdentity: ProcessIdentity?, address: String) throws -> FlowDescriptor {
    FlowDescriptor(
        flowID: UUID(),
        observedAt: Date(timeIntervalSince1970: 1_700_000_000),
        sourceAppIdentity: appIdentity,
        sourceProcessIdentity: nil,
        owner: .user(uid: 501),
        direction: .outgoing,
        transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress(address),
            port: 443,
            hostname: nil,
            hostnameCoverage: .absent,
            classes: [],
            interfaceSnapshotGeneration: 1
        ),
        observedHostname: nil,
        metadataConfidence: [.appIdentity, .endpoint]
    )
}

private final class LockedResolutions: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PromptResolution] = []

    func append(_ value: PromptResolution) { lock.withLock { values.append(value) } }
    func load() -> [PromptResolution] { lock.withLock { values } }
}

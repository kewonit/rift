import RiftCore
import RiftIPC
import Foundation
import Testing
@testable import RiftFilterRuntime

@Test func identityAdmissionHonorsAnyProcessDenyAndDefiniteVisibility() throws {
    let fixture = IdentityAdmissionFixture()
    let decision = try fixture.decision(
        mode: .alert,
        rules: [fixture.rule(action: .filter(.deny))]
    )

    let fallback = IdentityResolutionAdmissionPolicy.fallback(for: decision)
    #expect(fallback.action == .deny)
    #expect(fallback.reason == .concreteDecision)
    #expect(fallback.privacy == .visible)
    #expect(fallback.permitsMetadataRecord)
    #expect(fallback.shouldReport)
}

@Test func identityAdmissionHonorsUnmatchedSilentDeny() throws {
    let fixture = IdentityAdmissionFixture()
    let decision = try fixture.decision(mode: .silentDeny, rules: [])

    let fallback = IdentityResolutionAdmissionPolicy.fallback(for: decision)
    #expect(fallback.action == .deny)
    #expect(fallback.reason == .unmatchedModeFallback)
    #expect(fallback.privacy == .visible)
}

@Test func identityAdmissionBoundsAlertAskToAllowFallback() throws {
    let fixture = IdentityAdmissionFixture()
    let decision = try fixture.decision(mode: .alert, rules: [])

    let fallback = IdentityResolutionAdmissionPolicy.fallback(for: decision)
    #expect(decision.filter.action == .ask)
    #expect(fallback.action == .allow)
    #expect(fallback.reason == .promptUnavailableFallback)
    #expect(fallback.permitsMetadataRecord)
}

@Test func identityFailureUsesPartialAppForExactDenyWithoutTelemetry() throws {
    let fixture = IdentityAdmissionFixture()
    let app = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "ABCDE12345",
        signingIdentifier: "com.example.partial-app"
    ))
    let decision = try fixture.decision(
        mode: .alert,
        rules: [fixture.rule(action: .filter(.deny), process: .exact(app))],
        sourceAppIdentity: app
    )

    let fallback = IdentityResolutionAdmissionPolicy.fallback(
        for: decision,
        identityResolutionFailed: true
    )
    #expect(decision.filter.action == .deny)
    #expect(fallback.action == .deny)
    #expect(fallback.reason == .concreteDecision)
    #expect(fallback.privacy == .unresolved)
    #expect(!fallback.permitsMetadataRecord)
    #expect(!fallback.shouldReport)
}

@Test func identityFailureUsesPartialHelperForExactDenyWithoutTelemetry() throws {
    let fixture = IdentityAdmissionFixture()
    let helper = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "ABCDE12345",
        signingIdentifier: "com.example.partial-helper"
    ))
    let decision = try fixture.decision(
        mode: .alert,
        rules: [fixture.rule(action: .filter(.deny), process: .exact(helper))],
        sourceProcessIdentity: helper
    )

    let fallback = IdentityResolutionAdmissionPolicy.fallback(
        for: decision,
        identityResolutionFailed: true
    )
    #expect(decision.filter.action == .deny)
    #expect(fallback.action == .deny)
    #expect(fallback.privacy == .unresolved)
    #expect(!fallback.permitsMetadataRecord)
    #expect(!fallback.shouldReport)
}

@Test func identityAdmissionSuppressesAnyProcessPrivacyHide() throws {
    let fixture = IdentityAdmissionFixture()
    let decision = try fixture.decision(
        mode: .silentAllow,
        rules: [fixture.rule(action: .privacy(.hide))]
    )

    let fallback = IdentityResolutionAdmissionPolicy.fallback(for: decision)
    #expect(fallback.privacy == .hidden)
    #expect(!fallback.permitsMetadataRecord)
    #expect(!fallback.shouldReport)
}

@Test func identityAdmissionSuppressesIdentityDependentPrivacyUntilResolved() throws {
    let fixture = IdentityAdmissionFixture()
    let identity = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "ABCDE12345",
        signingIdentifier: "com.example.private"
    ))
    let decision = try fixture.decision(
        mode: .silentAllow,
        rules: [fixture.rule(action: .privacy(.hide), process: .exact(identity))]
    )

    let fallback = IdentityResolutionAdmissionPolicy.fallback(for: decision)
    #expect(decision.privacy.action == .visible)
    #expect(decision.issues.contains(DecisionIssue(
        category: .privacy,
        reason: .identityUnavailable
    )))
    #expect(fallback.privacy == .unresolved)
    #expect(!fallback.permitsMetadataRecord)
    #expect(!fallback.shouldReport)
}

@Test func pendingAdmissionDistinguishesDuplicateFromCapacity() {
    #expect(PendingFlowAdmissionPolicy.classify(
        currentCount: 255,
        containsFlowID: false,
        capacity: 256
    ) == .admitted)
    #expect(PendingFlowAdmissionPolicy.classify(
        currentCount: 256,
        containsFlowID: false,
        capacity: 256
    ) == .capacityExceeded)
    #expect(PendingFlowAdmissionPolicy.classify(
        currentCount: 256,
        containsFlowID: true,
        capacity: 256
    ) == .duplicate)
}

private struct IdentityAdmissionFixture {
    let lineageID = UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
    let now = Date(timeIntervalSince1970: 1_000)

    func decision(
        mode: OperationMode,
        rules: [Rule],
        sourceAppIdentity: ProcessIdentity? = nil,
        sourceProcessIdentity: ProcessIdentity? = nil
    ) throws -> Decision {
        let payload = try CompiledPolicyPayload(
            lineageID: lineageID,
            generation: 1,
            authorizedUID: 501,
            createdAt: now,
            operationMode: mode,
            activeProfileID: nil,
            enabledLocalGroupIDs: [],
            rules: rules
        )
        let artifact = try PolicyArtifact.compile(payload)
        let recovered = RecoveredPolicy(
            tuple: PolicyTuple(lineageID: lineageID, generation: 1, hash: artifact.hash),
            artifact: artifact,
            payload: payload,
            recoveredAfterLostAcknowledgement: false
        )
        return RuntimePolicy(recovered: recovered).decision(
            for: flow(
                sourceAppIdentity: sourceAppIdentity,
                sourceProcessIdentity: sourceProcessIdentity
            ),
            now: now
        )
    }

    func rule(
        action: RuleAction,
        process: ProcessCondition = .anyProcess
    ) throws -> Rule {
        try Rule(
            id: UUID(),
            lineageID: lineageID,
            revision: 1,
            action: action,
            priority: .normal,
            process: process,
            destination: .anyEndpoint,
            transportProtocol: .anySupportedProtocol,
            port: nil,
            direction: .bidirectional,
            owner: .authorizedUser,
            createdAt: now,
            modifiedAt: now
        )
    }

    private func flow(
        sourceAppIdentity: ProcessIdentity?,
        sourceProcessIdentity: ProcessIdentity?
    ) -> FlowDescriptor {
        FlowDescriptor(
            flowID: UUID(),
            observedAt: now,
            sourceAppIdentity: sourceAppIdentity,
            sourceProcessIdentity: sourceProcessIdentity,
            owner: .user(uid: 501),
            direction: .outgoing,
            transportProtocol: .tcp,
            localEndpoint: nil,
            remoteEndpoint: Endpoint(
                address: try! IPAddress("203.0.113.7"),
                port: 443,
                hostname: nil,
                hostnameCoverage: .absent,
                classes: [],
                interfaceSnapshotGeneration: 1
            ),
            observedHostname: nil,
            metadataConfidence: [.endpoint, .owner]
        )
    }
}

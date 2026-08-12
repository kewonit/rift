import AbyssCore
import AbyssIPC
import Foundation
import Testing
@testable import AbyssControl

@Test func initialLineageResumesAClaimWithNoPolicyEvidence() throws {
    let lineageID = UUID()
    let handshake = safetyHandshake(boundLineageID: lineageID)

    #expect(
        try ControlPlaneSafety.initialLineageResolution(handshake: handshake)
            == .resume(lineageID)
    )
}

@Test func initialLineageCreatesOnlyWhenNoClaimIsDisclosed() throws {
    let handshake = safetyHandshake()

    #expect(
        try ControlPlaneSafety.initialLineageResolution(handshake: handshake) == .unclaimed
    )
}

@Test func initialLineageRejectsExistingPolicyEvidence() {
    let lineageID = UUID()
    let tuple = PolicyTuple(lineageID: lineageID, generation: 1, hash: safetyHash(1))
    let handshakes = [
        safetyHandshake(boundLineageID: lineageID, highWater: 1),
        safetyHandshake(boundLineageID: lineageID, persisted: tuple),
        safetyHandshake(boundLineageID: lineageID, active: tuple),
    ]

    for handshake in handshakes {
        #expect(throws: ControlPlaneSafetyError.localConfigurationMissing) {
            try ControlPlaneSafety.initialLineageResolution(handshake: handshake)
        }
    }
}

@Test func durablePromptRequiresExactLivePolicyAndPendingPrompt() throws {
    let fixture = DurablePromptFixture()

    try ControlPlaneSafety.validateDurablePrompt(
        fixture.prompt,
        pendingPrompts: [fixture.prompt],
        handshake: fixture.handshake,
        desiredPolicy: fixture.tuple,
        configuration: fixture.configuration,
        requestedProfileID: fixture.profile.id,
        now: fixture.now
    )

    #expect(throws: ControlPlaneSafetyError.stalePrompt) {
        try ControlPlaneSafety.validateDurablePrompt(
            fixture.prompt,
            pendingPrompts: [],
            handshake: fixture.handshake,
            desiredPolicy: fixture.tuple,
            configuration: fixture.configuration,
            requestedProfileID: fixture.profile.id,
            now: fixture.now
        )
    }
    #expect(throws: ControlPlaneSafetyError.stalePrompt) {
        try ControlPlaneSafety.validateDurablePrompt(
            fixture.prompt,
            pendingPrompts: [fixture.prompt],
            handshake: safetyHandshake(
                providerEpoch: fixture.prompt.providerEpoch,
                boundLineageID: fixture.prompt.lineageID,
                highWater: fixture.prompt.generation,
                active: PolicyTuple(
                    lineageID: fixture.tuple.lineageID,
                    generation: fixture.tuple.generation,
                    hash: safetyHash(2)
                ),
                controllerLeaseID: UUID()
            ),
            desiredPolicy: fixture.tuple,
            configuration: fixture.configuration,
            requestedProfileID: fixture.profile.id,
            now: fixture.now
        )
    }
}

@Test func durablePromptRejectsGenerationAndCurrentProfileChanges() throws {
    let fixture = DurablePromptFixture()
    let newerDesired = PolicyTuple(
        lineageID: fixture.tuple.lineageID,
        generation: fixture.tuple.generation + 1,
        hash: safetyHash(3)
    )
    #expect(throws: ControlPlaneSafetyError.stalePrompt) {
        try ControlPlaneSafety.validateDurablePrompt(
            fixture.prompt,
            pendingPrompts: [fixture.prompt],
            handshake: fixture.handshake,
            desiredPolicy: newerDesired,
            configuration: fixture.configuration,
            requestedProfileID: fixture.profile.id,
            now: fixture.now
        )
    }

    let replacementProfile = PolicyProfile(
        id: UUID(), name: "Replacement", symbolName: nil,
        operationModeOverride: nil, createdAt: fixture.now, modifiedAt: fixture.now
    )
    let changedConfiguration = PolicyConfigurationDraft(
        lineageID: fixture.configuration.lineageID,
        authorizedUID: fixture.configuration.authorizedUID,
        operationMode: fixture.configuration.operationMode,
        activeProfileID: replacementProfile.id,
        enabledLocalGroupIDs: [],
        rules: [],
        profiles: [fixture.profile, replacementProfile]
    )
    #expect(throws: ControlPlaneSafetyError.stalePrompt) {
        try ControlPlaneSafety.validateDurablePrompt(
            fixture.prompt,
            pendingPrompts: [fixture.prompt],
            handshake: fixture.handshake,
            desiredPolicy: fixture.tuple,
            configuration: changedConfiguration,
            requestedProfileID: fixture.profile.id,
            now: fixture.now
        )
    }
}

private struct DurablePromptFixture {
    let now: Date
    let tuple: PolicyTuple
    let prompt: PromptRequest
    let profile: PolicyProfile
    let configuration: PolicyConfigurationDraft
    let handshake: HandshakeState

    init() {
        let now = Date(timeIntervalSince1970: 105)
        let lineageID = UUID()
        let providerEpoch = UUID()
        let tuple = PolicyTuple(lineageID: lineageID, generation: 7, hash: safetyHash(1))
        let prompt = PromptRequest(
            nonce: UUID(), providerEpoch: providerEpoch, lineageID: lineageID,
            generation: tuple.generation, flowID: UUID(),
            observedAt: Date(timeIntervalSince1970: 100),
            deadline: Date(timeIntervalSince1970: 110), owner: .user(uid: 501),
            appIdentity: nil, processIdentity: nil, direction: .outgoing,
            transportProtocol: .tcp, endpoint: nil,
            winningRuleID: nil, affectingRuleIDs: []
        )
        let profile = PolicyProfile(
            id: UUID(), name: "Current", symbolName: nil,
            operationModeOverride: nil, createdAt: now, modifiedAt: now
        )
        let configuration = PolicyConfigurationDraft(
            lineageID: lineageID, authorizedUID: 501, operationMode: .alert,
            activeProfileID: profile.id, enabledLocalGroupIDs: [], rules: [],
            profiles: [profile]
        )
        let handshake = safetyHandshake(
            providerEpoch: providerEpoch, boundLineageID: lineageID,
            highWater: tuple.generation, persisted: tuple, active: tuple,
            controllerLeaseID: UUID()
        )
        self.now = now
        self.tuple = tuple
        self.prompt = prompt
        self.profile = profile
        self.configuration = configuration
        self.handshake = handshake
    }
}

private func safetyHandshake(
    providerEpoch: UUID? = nil,
    boundLineageID: UUID? = nil,
    highWater: UInt64 = 0,
    persisted: PolicyTuple? = nil,
    active: PolicyTuple? = nil,
    controllerLeaseID: UUID? = nil
) -> HandshakeState {
    HandshakeState(
        runtimeInstanceID: UUID(), providerEpoch: providerEpoch, readiness: .ready,
        protocolRange: ProtocolRange(minimum: .current, maximum: .current),
        snapshotSchemaRange: 1...1, acceptedGenerationHighWater: highWater,
        boundLineageID: boundLineageID, persisted: persisted, active: active,
        controllerLeaseID: controllerLeaseID
    )
}

private func safetyHash(_ byte: UInt8) -> Data {
    Data(repeating: byte, count: 32)
}

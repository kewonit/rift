import AbyssControl
import AbyssIPC
import Foundation
import Testing

@Test func enforcementPresentationRequiresExactLiveProviderEvidence() {
    let desired = policyTuple(generation: 3, byte: 3)
    let exact = handshake(active: desired, readiness: .ready, hasEpoch: true)
    #expect(PolicyEnforcementPresentation.state(
        persistedState: .savedPendingEnforcement,
        desiredTuple: desired,
        handshake: exact
    ) == .enforced)

    let stale = handshake(
        active: policyTuple(generation: 2, byte: 2),
        readiness: .ready,
        hasEpoch: true
    )
    #expect(PolicyEnforcementPresentation.state(
        persistedState: .enforced,
        desiredTuple: desired,
        handshake: stale
    ) == .persistedPendingProvider)
    #expect(PolicyEnforcementPresentation.state(
        persistedState: .enforced,
        desiredTuple: desired,
        handshake: nil
    ) == .persistedPendingProvider)
    #expect(PolicyEnforcementPresentation.state(
        persistedState: .applyFailed,
        desiredTuple: desired,
        handshake: handshake(active: desired, readiness: .degradedNoPolicy, hasEpoch: true)
    ) == .applyFailed)
    #expect(PolicyEnforcementPresentation.state(
        persistedState: .enforced,
        desiredTuple: desired,
        handshake: handshake(active: desired, readiness: .ready, hasEpoch: false)
    ) == .persistedPendingProvider)
}

private func policyTuple(generation: UInt64, byte: UInt8) -> PolicyTuple {
    PolicyTuple(lineageID: UUID(), generation: generation, hash: Data(repeating: byte, count: 32))
}

private func handshake(
    active: PolicyTuple?,
    readiness: ProviderReadiness,
    hasEpoch: Bool
) -> HandshakeState {
    HandshakeState(
        runtimeInstanceID: UUID(),
        providerEpoch: hasEpoch ? UUID() : nil,
        readiness: readiness,
        protocolRange: ProtocolRange(minimum: .current, maximum: .current),
        snapshotSchemaRange: 1...1,
        acceptedGenerationHighWater: active?.generation ?? 0,
        boundLineageID: active?.lineageID,
        persisted: active,
        active: active,
        controllerLeaseID: UUID()
    )
}

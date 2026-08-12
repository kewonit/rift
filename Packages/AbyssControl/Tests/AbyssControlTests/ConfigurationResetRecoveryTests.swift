import AbyssIPC
import Foundation
import Testing
@testable import AbyssControl

@Test func configurationResetBeginsOnlyFromConsistentOwnedRootEvidence() throws {
    let old = UUID()
    let proposed = UUID()
    let tuple = PolicyTuple(lineageID: old, generation: 4, hash: Data(repeating: 7, count: 32))
    let plan = try ConfigurationResetRecovery.plan(
        from: resetHandshake(
            highWater: 4,
            bound: old,
            persisted: tuple,
            active: tuple
        ),
        proposedLineageID: proposed
    )
    #expect(plan == ConfigurationResetPlan(
        claimLineageID: old,
        targetLineageID: proposed,
        isResuming: false
    ))
}

@Test func interruptedConfigurationResetReusesAuthenticatedTarget() throws {
    let target = UUID()
    let plan = try ConfigurationResetRecovery.plan(
        from: resetHandshake(
            highWater: 0,
            bound: target,
            configurationReset: target
        ),
        proposedLineageID: UUID()
    )
    #expect(plan.claimLineageID == target)
    #expect(plan.targetLineageID == target)
    #expect(plan.isResuming)
}

@Test func configurationResetRejectsUnavailableOwnerOldProtocolAndInconsistentEvidence() {
    #expect(throws: ConfigurationResetRecoveryError.ownerUnavailable) {
        _ = try ConfigurationResetRecovery.plan(
            from: resetHandshake(highWater: 0),
            proposedLineageID: UUID()
        )
    }
    #expect(throws: ConfigurationResetRecoveryError.unsupportedProtocol) {
        _ = try ConfigurationResetRecovery.plan(
            from: resetHandshake(
                maximumProtocol: .baseline,
                highWater: 1,
                bound: UUID()
            ),
            proposedLineageID: UUID()
        )
    }
    let target = UUID()
    #expect(throws: ConfigurationResetRecoveryError.inconsistentRootState) {
        _ = try ConfigurationResetRecovery.plan(
            from: resetHandshake(
                highWater: 1,
                bound: target,
                configurationReset: target
            ),
            proposedLineageID: UUID()
        )
    }
}

private func resetHandshake(
    maximumProtocol: ProtocolVersion = .current,
    highWater: UInt64,
    bound: UUID? = nil,
    configurationReset: UUID? = nil,
    persisted: PolicyTuple? = nil,
    active: PolicyTuple? = nil
) -> HandshakeState {
    HandshakeState(
        runtimeInstanceID: UUID(),
        providerEpoch: UUID(),
        readiness: .ready,
        protocolRange: ProtocolRange(minimum: .baseline, maximum: maximumProtocol),
        snapshotSchemaRange: 1...1,
        acceptedGenerationHighWater: highWater,
        boundLineageID: bound,
        configurationResetLineageID: configurationReset,
        persisted: persisted,
        active: active,
        controllerLeaseID: nil
    )
}

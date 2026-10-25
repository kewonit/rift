import RiftCore
import RiftIPC
import Foundation
import Testing
@testable import RiftControl

@Suite("Offline mutation safety")
struct OfflineMutationSafetyTests {
    @Test func authenticatedAnchorRequiresBoundConsistentRootTruth() throws {
        let lineage = UUID()
        let desired = tuple(lineage: lineage, generation: 4, hashByte: 4)
        let valid = handshake(
            lineage: lineage,
            highWater: 4,
            persisted: desired,
            active: desired
        )

        let anchor = try OfflineMutationSafety.authenticate(
            handshake: valid,
            localDesired: desired
        )

        #expect(anchor.lineageID == lineage)
        #expect(anchor.acceptedGenerationHighWater == 4)
        #expect(throws: OfflineMutationSafetyError.authenticatedHighWaterUnavailable) {
            try OfflineMutationSafety.authenticate(
                handshake: handshake(lineage: nil, highWater: 0),
                localDesired: desired
            )
        }
        #expect(throws: OfflineMutationSafetyError.lineageMismatch) {
            try OfflineMutationSafety.authenticate(
                handshake: handshake(lineage: UUID(), highWater: 0),
                localDesired: desired
            )
        }
    }

    @Test func rootAheadAndSameGenerationDivergenceFailClosed() throws {
        let lineage = UUID()
        let desired = tuple(lineage: lineage, generation: 4, hashByte: 4)

        #expect(throws: OfflineMutationSafetyError.rootGenerationAhead) {
            try OfflineMutationSafety.authenticate(
                handshake: handshake(lineage: lineage, highWater: 5),
                localDesired: desired
            )
        }
        #expect(throws: OfflineMutationSafetyError.localStateDiverged) {
            try OfflineMutationSafety.authenticate(
                handshake: handshake(
                    lineage: lineage,
                    highWater: 4,
                    persisted: tuple(lineage: lineage, generation: 4, hashByte: 9)
                ),
                localDesired: desired
            )
        }
    }

    @Test func cachedAnchorRejectsRollbackDivergenceAndRecovery() throws {
        let lineage = UUID()
        let authenticated = tuple(lineage: lineage, generation: 4, hashByte: 4)
        let anchor = try OfflineMutationSafety.authenticate(
            handshake: handshake(
                lineage: lineage,
                highWater: 4,
                persisted: authenticated
            ),
            localDesired: authenticated
        )

        #expect(throws: OfflineMutationSafetyError.rootGenerationAhead) {
            try OfflineMutationSafety.validateOfflineSave(
                anchor: anchor,
                localDesired: tuple(lineage: lineage, generation: 3, hashByte: 3),
                recoveryInProgress: false
            )
        }
        #expect(throws: OfflineMutationSafetyError.localStateDiverged) {
            try OfflineMutationSafety.validateOfflineSave(
                anchor: anchor,
                localDesired: tuple(lineage: lineage, generation: 4, hashByte: 8),
                recoveryInProgress: false
            )
        }
        #expect(throws: OfflineMutationSafetyError.recoveryInProgress) {
            try OfflineMutationSafety.validateOfflineSave(
                anchor: anchor,
                localDesired: authenticated,
                recoveryInProgress: true
            )
        }
    }

    @Test func offlineRepositorySaveAdvancesLocallyAndPreservesCAS() async throws {
        let context = try OfflineRepositoryContext()
        defer { context.remove() }
        let initialDraft = context.draft(mode: .silentAllow)
        let initial = try await context.repository.save(
            initialDraft,
            extensionHighWater: 3,
            expectedGeneration: 0,
            commandKind: "initial",
            redactedSummary: "initial",
            now: Date(timeIntervalSince1970: 100)
        )
        let anchor = try OfflineMutationSafety.authenticate(
            handshake: handshake(
                lineage: context.lineage,
                highWater: initial.tuple.generation,
                persisted: initial.tuple
            ),
            localDesired: initial.tuple
        )

        let firstOffline = try await context.repository.saveOffline(
            context.draft(mode: .silentDeny),
            authenticatedRoot: anchor,
            expectedGeneration: initial.tuple.generation,
            commandKind: "offlineOne",
            redactedSummary: "offlineOne",
            now: Date(timeIntervalSince1970: 101)
        )
        let secondOffline = try await context.repository.saveOffline(
            context.draft(mode: .alert),
            authenticatedRoot: anchor,
            expectedGeneration: firstOffline.tuple.generation,
            commandKind: "offlineTwo",
            redactedSummary: "offlineTwo",
            now: Date(timeIntervalSince1970: 102)
        )

        #expect(firstOffline.tuple.generation == 5)
        #expect(secondOffline.tuple.generation == 6)
        #expect(secondOffline.state == .savedPendingEnforcement)
        #expect(try await context.repository.currentConfiguration()?.operationMode == .alert)
        await #expect(throws: PolicyRepositoryError.generationConflict) {
            try await context.repository.saveOffline(
                context.draft(mode: .silentAllow),
                authenticatedRoot: anchor,
                expectedGeneration: firstOffline.tuple.generation,
                commandKind: "stale",
                redactedSummary: "stale",
                now: Date(timeIntervalSince1970: 103)
            )
        }
        #expect(try await context.repository.newestDesiredPolicy()?.tuple == secondOffline.tuple)
    }

    @Test func offlineRepositorySaveRejectsPendingRestoreAtomically() async throws {
        let context = try OfflineRepositoryContext()
        defer { context.remove() }
        let initial = try await context.repository.save(
            context.draft(mode: .silentAllow),
            extensionHighWater: 0,
            expectedGeneration: 0,
            restoreBackupName: "pre-restore-100-deadbeef.sqlite",
            commandKind: "restore",
            redactedSummary: "restore",
            now: Date(timeIntervalSince1970: 100)
        )
        let anchor = try OfflineMutationSafety.authenticate(
            handshake: handshake(
                lineage: context.lineage,
                highWater: initial.tuple.generation,
                persisted: initial.tuple
            ),
            localDesired: initial.tuple
        )

        await #expect(throws: OfflineMutationSafetyError.recoveryInProgress) {
            try await context.repository.saveOffline(
                context.draft(mode: .silentDeny),
                authenticatedRoot: anchor,
                expectedGeneration: initial.tuple.generation,
                commandKind: "blocked",
                redactedSummary: "blocked",
                now: Date(timeIntervalSince1970: 101)
            )
        }
        #expect(try await context.repository.newestDesiredPolicy()?.tuple == initial.tuple)
        #expect(try await context.repository.currentConfiguration()?.operationMode == .silentAllow)
    }
}

private struct OfflineRepositoryContext {
    let directory: URL
    let repository: PolicyRepository
    let lineage = UUID()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = PolicyRepository(
            database: try ConfigurationDatabase.open(
                at: directory.appendingPathComponent("config.sqlite")
            )
        )
    }

    func draft(mode: OperationMode) -> PolicyConfigurationDraft {
        PolicyConfigurationDraft(
            lineageID: lineage,
            authorizedUID: 501,
            operationMode: mode,
            activeProfileID: nil,
            enabledLocalGroupIDs: [],
            rules: []
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private func tuple(lineage: UUID, generation: UInt64, hashByte: UInt8) -> PolicyTuple {
    PolicyTuple(
        lineageID: lineage,
        generation: generation,
        hash: Data(repeating: hashByte, count: 32)
    )
}

private func handshake(
    lineage: UUID?,
    highWater: UInt64,
    persisted: PolicyTuple? = nil,
    active: PolicyTuple? = nil
) -> HandshakeState {
    HandshakeState(
        runtimeInstanceID: UUID(),
        providerEpoch: active == nil ? nil : UUID(),
        readiness: active == nil ? .unavailable : .ready,
        protocolRange: ProtocolRange(minimum: .current, maximum: .current),
        snapshotSchemaRange: 1...CompiledPolicyPayload.currentSchemaVersion,
        acceptedGenerationHighWater: highWater,
        boundLineageID: lineage,
        persisted: persisted,
        active: active,
        controllerLeaseID: nil
    )
}

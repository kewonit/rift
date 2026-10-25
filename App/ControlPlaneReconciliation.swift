import RiftCore
import RiftControl
import RiftIPC
import Darwin
import Foundation

extension ControlPlaneController {
    func reconcileNewest(lineageID: UUID) async throws {
        guard let repository,
              let desired = try await repository.newestDesiredPolicy() else { return }
        recordSavedDesiredPolicy(desired.tuple)
        let handshake = try await client.handshake()
        recordHandshake(handshake)
        if handshake.active == desired.tuple, let epoch = handshake.providerEpoch {
            try await repository.markEnforced(
                desired.tuple,
                providerEpoch: epoch,
                at: Date()
            )
            try await repository.clearPendingRestoreRecovery(
                throughGeneration: desired.tuple.generation
            )
            pendingRestoreBackupURL = nil
            return
        }
        if handshake.persisted == desired.tuple, handshake.providerEpoch == nil {
            try await repository.markPersisted(desired.tuple, at: Date())
            return
        }
        _ = try await client.claimController(lineageID: lineageID)
        let result = try await client.apply(DesiredTransfer(
            tuple: desired.tuple,
            bytes: desired.artifact.bytes
        ))
        switch result.disposition {
        case .persisted, .idempotent:
            try await repository.markPersisted(result.tuple, at: Date())
        case .active:
            guard let epoch = result.providerEpoch else {
                throw ControlPlaneControllerError.missingProviderEpoch
            }
            try await repository.markEnforced(result.tuple, providerEpoch: epoch, at: Date())
            recordActivePolicy(result.tuple)
            try await repository.clearPendingRestoreRecovery(
                throughGeneration: result.tuple.generation
            )
            pendingRestoreBackupURL = nil
        }
    }

    func reconcileSavedPolicy(_ desired: DesiredPolicy, lineageID: UUID) async throws {
        recordSavedDesiredPolicy(desired.tuple)
        do {
            try await reconcileNewest(lineageID: lineageID)
        } catch {
            guard let repository else { throw error }
            try await repository.markApplyFailed(desired.tuple, at: Date())
            throw error
        }
    }

    func establishController(handshake: HandshakeState) async throws {
        guard let repository else { return }
        if let configuration = try await repository.currentConfiguration() {
            _ = try await client.claimController(lineageID: configuration.lineageID)
            try await reconcileNewest(lineageID: configuration.lineageID)
            return
        }
        let lineageID: UUID
        switch try ControlPlaneSafety.initialLineageResolution(handshake: handshake) {
        case .resume(let existingLineageID):
            lineageID = existingLineageID
        case .unclaimed:
            lineageID = UUID()
        }
        _ = try await client.claimController(lineageID: lineageID)
        let initial = PolicyConfigurationDraft(
            lineageID: lineageID,
            authorizedUID: getuid(),
            operationMode: .silentAllow,
            activeProfileID: nil,
            enabledLocalGroupIDs: [],
            rules: []
        )
        let desired = try await repository.save(
            initial,
            extensionHighWater: handshake.acceptedGenerationHighWater,
            commandKind: "initialPolicy",
            redactedSummary: "silentAllow",
            now: Date()
        )
        try await reconcileSavedPolicy(desired, lineageID: lineageID)
    }
}

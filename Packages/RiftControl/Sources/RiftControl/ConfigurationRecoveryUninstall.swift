import RiftIPC
import Foundation

public enum ConfigurationRecoveryUninstallError: Error, Sendable, Equatable {
    case inconsistentRootState
}

public enum ConfigurationRecoveryUninstall {
    public static func claimLineageID(
        from handshake: HandshakeState,
        undisclosedLineageID: UUID
    ) throws -> UUID {
        let policyTuples = [handshake.persisted, handshake.active].compactMap { $0 }
        if let configurationResetLineageID = handshake.configurationResetLineageID {
            guard handshake.boundLineageID == configurationResetLineageID,
                  handshake.acceptedGenerationHighWater == 0,
                  policyTuples.isEmpty else {
                throw ConfigurationRecoveryUninstallError.inconsistentRootState
            }
        }
        if let boundLineageID = handshake.boundLineageID {
            guard policyTuples.allSatisfy({
                $0.lineageID == boundLineageID
                    && $0.generation <= handshake.acceptedGenerationHighWater
            }) else {
                throw ConfigurationRecoveryUninstallError.inconsistentRootState
            }
            if let persisted = handshake.persisted, let active = handshake.active {
                guard active.generation <= persisted.generation,
                      active.generation != persisted.generation
                        || active.hash == persisted.hash else {
                    throw ConfigurationRecoveryUninstallError.inconsistentRootState
                }
            }
            return boundLineageID
        }

        guard handshake.acceptedGenerationHighWater == 0,
              policyTuples.isEmpty,
              handshake.controllerLeaseID == nil else {
            throw ConfigurationRecoveryUninstallError.inconsistentRootState
        }
        return undisclosedLineageID
    }

    public static func prepare<ConnectionID: Sendable>(
        undisclosedLineageID: UUID,
        connect: @Sendable () async throws -> ConnectionID,
        handshake: @Sendable () async throws -> HandshakeState,
        requireCurrentConnection: @Sendable (ConnectionID) async throws -> Void,
        claimController: @Sendable (UUID, ConnectionID) async throws -> Void,
        prepareUninstall: @Sendable () async throws -> Void
    ) async throws {
        try Task.checkCancellation()
        let connectionID = try await connect()
        try Task.checkCancellation()
        let authenticatedHandshake = try await handshake()
        try Task.checkCancellation()
        try await requireCurrentConnection(connectionID)
        let lineageID = try claimLineageID(
            from: authenticatedHandshake,
            undisclosedLineageID: undisclosedLineageID
        )
        try Task.checkCancellation()
        try await claimController(lineageID, connectionID)
        try Task.checkCancellation()
        try await requireCurrentConnection(connectionID)
        try Task.checkCancellation()
        try await prepareUninstall()
    }
}

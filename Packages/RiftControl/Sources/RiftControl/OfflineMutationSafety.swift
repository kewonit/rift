import RiftIPC
import Foundation

public struct AuthenticatedRootHighWater: Sendable, Equatable {
    public let lineageID: UUID
    public let acceptedGenerationHighWater: UInt64
    let localDesiredAtAuthentication: PolicyTuple

    init(
        lineageID: UUID,
        acceptedGenerationHighWater: UInt64,
        localDesiredAtAuthentication: PolicyTuple
    ) {
        self.lineageID = lineageID
        self.acceptedGenerationHighWater = acceptedGenerationHighWater
        self.localDesiredAtAuthentication = localDesiredAtAuthentication
    }
}

public enum OfflineMutationSafetyError: Error, Sendable, Equatable {
    case authenticatedHighWaterUnavailable
    case lineageMismatch
    case rootGenerationAhead
    case localStateDiverged
    case recoveryInProgress
}

public enum OfflineMutationSafety {
    public static func authenticate(
        handshake: HandshakeState,
        localDesired: PolicyTuple
    ) throws -> AuthenticatedRootHighWater {
        guard let rootLineage = handshake.boundLineageID else {
            throw OfflineMutationSafetyError.authenticatedHighWaterUnavailable
        }
        guard rootLineage == localDesired.lineageID else {
            throw OfflineMutationSafetyError.lineageMismatch
        }
        let disclosed = [handshake.persisted, handshake.active].compactMap { $0 }
        guard disclosed.allSatisfy({
            $0.lineageID == rootLineage
                && $0.generation <= handshake.acceptedGenerationHighWater
        }) else {
            throw OfflineMutationSafetyError.localStateDiverged
        }
        guard handshake.acceptedGenerationHighWater <= localDesired.generation else {
            throw OfflineMutationSafetyError.rootGenerationAhead
        }
        if handshake.acceptedGenerationHighWater == localDesired.generation {
            guard disclosed.lazy
                .filter({ $0.generation == localDesired.generation })
                .allSatisfy({ $0 == localDesired }) else {
                throw OfflineMutationSafetyError.localStateDiverged
            }
        }
        return AuthenticatedRootHighWater(
            lineageID: rootLineage,
            acceptedGenerationHighWater: handshake.acceptedGenerationHighWater,
            localDesiredAtAuthentication: localDesired
        )
    }

    static func validateOfflineSave(
        anchor: AuthenticatedRootHighWater,
        localDesired: PolicyTuple,
        recoveryInProgress: Bool
    ) throws -> UInt64 {
        guard !recoveryInProgress else {
            throw OfflineMutationSafetyError.recoveryInProgress
        }
        guard anchor.lineageID == localDesired.lineageID,
              anchor.localDesiredAtAuthentication.lineageID == localDesired.lineageID else {
            throw OfflineMutationSafetyError.lineageMismatch
        }
        guard anchor.acceptedGenerationHighWater <= localDesired.generation,
              anchor.localDesiredAtAuthentication.generation <= localDesired.generation else {
            throw OfflineMutationSafetyError.rootGenerationAhead
        }
        if anchor.localDesiredAtAuthentication.generation == localDesired.generation {
            guard anchor.localDesiredAtAuthentication == localDesired else {
                throw OfflineMutationSafetyError.localStateDiverged
            }
        }
        return anchor.acceptedGenerationHighWater
    }
}

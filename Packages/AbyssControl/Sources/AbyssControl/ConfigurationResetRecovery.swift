import AbyssIPC
import Foundation

public struct ConfigurationResetPlan: Sendable, Equatable {
    public let claimLineageID: UUID
    public let targetLineageID: UUID
    public let isResuming: Bool

    public init(claimLineageID: UUID, targetLineageID: UUID, isResuming: Bool) {
        self.claimLineageID = claimLineageID
        self.targetLineageID = targetLineageID
        self.isResuming = isResuming
    }
}

public enum ConfigurationResetRecoveryError: Error, Sendable, Equatable {
    case unsupportedProtocol
    case ownerUnavailable
    case inconsistentRootState
}

public enum ConfigurationResetRecovery {
    public static func plan(
        from handshake: HandshakeState,
        proposedLineageID: UUID
    ) throws -> ConfigurationResetPlan {
        guard handshake.protocolRange.maximum.supports(
            minimum: .configurationReset
        ) else {
            throw ConfigurationResetRecoveryError.unsupportedProtocol
        }
        if let target = handshake.configurationResetLineageID {
            guard handshake.boundLineageID == target,
                  handshake.acceptedGenerationHighWater == 0,
                  handshake.persisted == nil,
                  handshake.active == nil else {
                throw ConfigurationResetRecoveryError.inconsistentRootState
            }
            return ConfigurationResetPlan(
                claimLineageID: target,
                targetLineageID: target,
                isResuming: true
            )
        }
        guard let ownerLineageID = handshake.boundLineageID else {
            throw ConfigurationResetRecoveryError.ownerUnavailable
        }
        let tuples = [handshake.persisted, handshake.active].compactMap { $0 }
        guard ownerLineageID != proposedLineageID,
              tuples.allSatisfy({
                  $0.lineageID == ownerLineageID
                      && $0.generation <= handshake.acceptedGenerationHighWater
              }) else {
            throw ConfigurationResetRecoveryError.inconsistentRootState
        }
        if let persisted = handshake.persisted, let active = handshake.active {
            guard active.generation <= persisted.generation,
                  active.generation != persisted.generation
                    || active.hash == persisted.hash else {
                throw ConfigurationResetRecoveryError.inconsistentRootState
            }
        }
        return ConfigurationResetPlan(
            claimLineageID: ownerLineageID,
            targetLineageID: proposedLineageID,
            isResuming: false
        )
    }
}

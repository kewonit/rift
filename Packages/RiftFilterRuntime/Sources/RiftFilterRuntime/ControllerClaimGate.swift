import Foundation

public enum ControllerClaimAuthorization: Sendable, Equatable {
    case claimFirstOwner
    case reconnectExistingOwner
    case resumeVerifiedUninstall
    case resumeConfigurationReset(targetLineageID: UUID)
}

public enum ControllerClaimAuthorizationError: Error, Sendable, Equatable {
    case initialClaimRequiresActiveProvider
    case foreignOwner
    case lineageMismatch
    case resetInProgress
}

public enum ControllerClaimGate {
    public static func authorize(
        ownership: RootOwnership,
        uid: UInt32,
        lineageID: UUID,
        providerEpoch: UUID?,
        persistenceState: ProviderPersistenceState
    ) throws -> ControllerClaimAuthorization {
        switch ownership {
        case .unclaimed:
            guard providerEpoch != nil, persistenceState.canActivatePolicy else {
                throw ControllerClaimAuthorizationError.initialClaimRequiresActiveProvider
            }
            return .claimFirstOwner
        case .owned(let ownerUID, let ownerLineage, _):
            guard ownerUID == uid else {
                throw ControllerClaimAuthorizationError.foreignOwner
            }
            guard ownerLineage == lineageID else {
                throw ControllerClaimAuthorizationError.lineageMismatch
            }
            return .reconnectExistingOwner
        case .resetting(let oldUID, _):
            guard oldUID == uid else {
                throw ControllerClaimAuthorizationError.foreignOwner
            }
            return .resumeVerifiedUninstall
        case .replacingConfiguration(let oldUID, let targetLineageID):
            guard oldUID == uid else {
                throw ControllerClaimAuthorizationError.foreignOwner
            }
            guard targetLineageID == lineageID else {
                throw ControllerClaimAuthorizationError.lineageMismatch
            }
            return .resumeConfigurationReset(targetLineageID: targetLineageID)
        }
    }
}

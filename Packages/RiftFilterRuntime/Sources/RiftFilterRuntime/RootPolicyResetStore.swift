import Foundation

extension RootPolicyStore {
    public func eraseForVerifiedUninstall(uid: UInt32) throws {
        try directory.withExclusiveLock {
            try beginVerifiedUninstallLocked(uid: uid)
            try erasePolicyArtifactsForVerifiedUninstallLocked(uid: uid)
            try finishVerifiedUninstallLocked(uid: uid)
        }
    }

    public func beginVerifiedUninstall(uid: UInt32) throws {
        try directory.withExclusiveLock { try beginVerifiedUninstallLocked(uid: uid) }
    }

    public func erasePolicyArtifactsForVerifiedUninstall(uid: UInt32) throws {
        try directory.withExclusiveLock {
            try erasePolicyArtifactsForVerifiedUninstallLocked(uid: uid)
        }
    }

    public func finishVerifiedUninstall(uid: UInt32) throws {
        try directory.withExclusiveLock { try finishVerifiedUninstallLocked(uid: uid) }
    }

    public func beginConfigurationReset(uid: UInt32, targetLineageID: UUID) throws {
        try directory.withExclusiveLock {
            switch try initializeIfNeededLocked() {
            case .owned(let ownerUID, let oldLineageID, _):
                guard ownerUID == uid else { throw RootPolicyStoreError.ownerMismatch }
                guard oldLineageID != targetLineageID else {
                    throw RootPolicyStoreError.lineageMismatch
                }
                try writeOwnership(.replacingConfiguration(
                    oldUID: uid,
                    targetLineageID: targetLineageID
                ))
            case .replacingConfiguration(let oldUID, let existingTarget):
                guard oldUID == uid else { throw RootPolicyStoreError.ownerMismatch }
                guard existingTarget == targetLineageID else {
                    throw RootPolicyStoreError.lineageMismatch
                }
            case .unclaimed, .resetting:
                throw RootPolicyStoreError.mutationLocked
            }
        }
    }

    public func erasePolicyArtifactsForConfigurationReset(
        uid: UInt32,
        targetLineageID: UUID
    ) throws {
        try directory.withExclusiveLock {
            guard case .replacingConfiguration(let oldUID, let existingTarget) =
                    try initializeIfNeededLocked() else {
                throw RootPolicyStoreError.mutationLocked
            }
            guard oldUID == uid else { throw RootPolicyStoreError.ownerMismatch }
            guard existingTarget == targetLineageID else {
                throw RootPolicyStoreError.lineageMismatch
            }
            try removePolicyArtifacts()
        }
    }

    private func beginVerifiedUninstallLocked(uid: UInt32) throws {
        switch try initializeIfNeededLocked() {
        case .owned(let ownerUID, _, _):
            guard ownerUID == uid else { throw RootPolicyStoreError.ownerMismatch }
            try writeOwnership(.resetting(oldUID: uid, targetLineageID: UUID()))
        case .resetting(let oldUID, _):
            guard oldUID == uid else { throw RootPolicyStoreError.ownerMismatch }
        case .unclaimed:
            break
        case .replacingConfiguration(let oldUID, _):
            guard oldUID == uid else { throw RootPolicyStoreError.ownerMismatch }
            try writeOwnership(.resetting(oldUID: uid, targetLineageID: UUID()))
        }
    }

    private func erasePolicyArtifactsForVerifiedUninstallLocked(uid: UInt32) throws {
        switch try initializeIfNeededLocked() {
        case .resetting(let oldUID, _):
            guard oldUID == uid else { throw RootPolicyStoreError.ownerMismatch }
        case .unclaimed:
            return
        case .owned, .replacingConfiguration:
            throw RootPolicyStoreError.mutationLocked
        }
        try removePolicyArtifacts()
    }

    private func finishVerifiedUninstallLocked(uid: UInt32) throws {
        switch try initializeIfNeededLocked() {
        case .resetting(let oldUID, _):
            guard oldUID == uid else { throw RootPolicyStoreError.ownerMismatch }
        case .unclaimed:
            return
        case .owned, .replacingConfiguration:
            throw RootPolicyStoreError.mutationLocked
        }
        guard try fixedSlotStates().allSatisfy(\.isAbsent) else {
            throw RootPolicyStoreError.residualSlotsWhileUnclaimed
        }
        try writeOwnership(.unclaimed)
    }

    private func removePolicyArtifacts() throws {
        try directory.remove(Self.slotAName)
        try directory.remove(Self.slotBName)
        try directory.remove(Self.slotIndexName)
    }
}

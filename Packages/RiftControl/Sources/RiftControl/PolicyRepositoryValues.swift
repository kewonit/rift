import RiftCore
import RiftIPC
import Foundation

public enum PolicyOutboxState: String, Sendable, Codable {
    case savedPendingEnforcement
    case persistedPendingProvider
    case enforced
    case applyFailed
}

public struct PolicyConfigurationDraft: Sendable {
    public let lineageID: UUID
    public let authorizedUID: UInt32
    public let operationMode: OperationMode
    public let baseOperationMode: OperationMode
    public let activeProfileID: UUID?
    public let enabledLocalGroupIDs: Set<UUID>
    public let rules: [Rule]
    public let localGroups: [LocalRuleGroup]
    public let profiles: [PolicyProfile]
    public let blocklists: [BlocklistSource]
    public let disabledBlocklistEntries: Set<BlocklistEntry>

    public init(
        lineageID: UUID,
        authorizedUID: UInt32,
        operationMode: OperationMode,
        baseOperationMode: OperationMode? = nil,
        activeProfileID: UUID?,
        enabledLocalGroupIDs: Set<UUID>,
        rules: [Rule],
        localGroups: [LocalRuleGroup] = [],
        profiles: [PolicyProfile] = [],
        blocklists: [BlocklistSource] = [],
        disabledBlocklistEntries: Set<BlocklistEntry> = []
    ) {
        self.lineageID = lineageID
        self.authorizedUID = authorizedUID
        self.operationMode = operationMode
        self.baseOperationMode = baseOperationMode ?? operationMode
        self.activeProfileID = activeProfileID
        self.enabledLocalGroupIDs = enabledLocalGroupIDs
        self.rules = rules
        self.localGroups = localGroups
        self.profiles = profiles
        self.blocklists = blocklists
        self.disabledBlocklistEntries = disabledBlocklistEntries
    }
}

public struct DesiredPolicy: Sendable, Hashable {
    public let tuple: PolicyTuple
    public let artifact: PolicyArtifact
    public let createdAt: Date
    public let state: PolicyOutboxState
    public let providerEpoch: UUID?
}

public struct PendingRestoreRecovery: Sendable, Hashable {
    public let backupName: String
    public let targetGeneration: UInt64
    public let createdAt: Date

    public init(backupName: String, targetGeneration: UInt64, createdAt: Date) {
        self.backupName = backupName
        self.targetGeneration = targetGeneration
        self.createdAt = createdAt
    }
}

public enum PolicyRepositoryError: Error, Sendable, Equatable {
    case generationOverflow
    case generationConflict
    case ownerMismatch
    case lineageMismatch
    case missingGeneration
    case acknowledgementMismatch
    case invalidRestoreBackupName
    case restoreRecoveryInProgress
}

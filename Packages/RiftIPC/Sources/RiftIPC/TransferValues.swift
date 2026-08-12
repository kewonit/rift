import Foundation

public enum IPCProtocolLimits {
    public static let maximumSnapshotBytes = 16 * 1_024 * 1_024
    public static let maximumChunkBytes = 256 * 1_024
    public static let maximumEnvelopePayloadBytes = 512 * 1_024
    public static let maximumReplyPayloadBytes = 2 * 1_024 * 1_024
    public static let maximumPromptBytes = 32 * 1_024
    public static let maximumEventBatchCount = 256
    public static let transferDeadlineSeconds: TimeInterval = 30
}

public struct ProtocolRange: Sendable, Hashable, Codable {
    public let minimum: ProtocolVersion
    public let maximum: ProtocolVersion

    public init(minimum: ProtocolVersion, maximum: ProtocolVersion) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func highestMutualVersion(with other: ProtocolRange) -> ProtocolVersion? {
        guard minimum.major == maximum.major,
              other.minimum.major == other.maximum.major,
              minimum.major == other.minimum.major else { return nil }
        let lower = max(minimum.minor, other.minimum.minor)
        let upper = min(maximum.minor, other.maximum.minor)
        return lower <= upper ? ProtocolVersion(major: minimum.major, minor: upper) : nil
    }
}

public struct PolicyTuple: Sendable, Hashable, Codable {
    public let lineageID: UUID
    public let generation: UInt64
    public let hash: Data

    public init(lineageID: UUID, generation: UInt64, hash: Data) {
        self.lineageID = lineageID
        self.generation = generation
        self.hash = hash
    }
}

public enum ProviderReadiness: String, Sendable, Hashable, Codable {
    case unavailable
    case starting
    case ready
    case degradedNoPolicy
    case degradedPersistence
}

public struct HandshakeState: Sendable, Hashable, Codable {
    public let runtimeInstanceID: UUID
    public let providerEpoch: UUID?
    public let readiness: ProviderReadiness
    public let protocolRange: ProtocolRange
    public let snapshotSchemaRange: ClosedRange<UInt16>
    public let acceptedGenerationHighWater: UInt64
    public let boundLineageID: UUID?
    public let configurationResetLineageID: UUID?
    public let persisted: PolicyTuple?
    public let active: PolicyTuple?
    public let controllerLeaseID: UUID?

    public init(
        runtimeInstanceID: UUID,
        providerEpoch: UUID?,
        readiness: ProviderReadiness,
        protocolRange: ProtocolRange,
        snapshotSchemaRange: ClosedRange<UInt16>,
        acceptedGenerationHighWater: UInt64,
        boundLineageID: UUID? = nil,
        configurationResetLineageID: UUID? = nil,
        persisted: PolicyTuple?,
        active: PolicyTuple?,
        controllerLeaseID: UUID?
    ) {
        self.runtimeInstanceID = runtimeInstanceID
        self.providerEpoch = providerEpoch
        self.readiness = readiness
        self.protocolRange = protocolRange
        self.snapshotSchemaRange = snapshotSchemaRange
        self.acceptedGenerationHighWater = acceptedGenerationHighWater
        self.boundLineageID = boundLineageID
        self.configurationResetLineageID = configurationResetLineageID
        self.persisted = persisted
        self.active = active
        self.controllerLeaseID = controllerLeaseID
    }
}

public struct SnapshotTransferBegin: Sendable, Hashable, Codable {
    public let lineageID: UUID
    public let generation: UInt64
    public let schemaVersion: UInt16
    public let byteCount: Int
    public let hash: Data

    public init(lineageID: UUID, generation: UInt64, schemaVersion: UInt16, byteCount: Int, hash: Data) {
        self.lineageID = lineageID
        self.generation = generation
        self.schemaVersion = schemaVersion
        self.byteCount = byteCount
        self.hash = hash
    }
}

public struct ClaimControllerRequest: Sendable, Hashable, Codable {
    public let lineageID: UUID

    public init(lineageID: UUID) {
        self.lineageID = lineageID
    }
}

public struct ConfigurationResetRequest: Sendable, Hashable, Codable {
    public let targetLineageID: UUID

    public init(targetLineageID: UUID) {
        self.targetLineageID = targetLineageID
    }
}

public struct SnapshotChunk: Sendable, Hashable, Codable {
    public let offset: Int
    public let bytes: Data

    public init(offset: Int, bytes: Data) {
        self.offset = offset
        self.bytes = bytes
    }
}

public struct SnapshotFinishResult: Sendable, Hashable, Codable {
    public let disposition: SnapshotApplyDisposition
    public let tuple: PolicyTuple
    public let providerEpoch: UUID?

    public init(disposition: SnapshotApplyDisposition, tuple: PolicyTuple, providerEpoch: UUID?) {
        self.disposition = disposition
        self.tuple = tuple
        self.providerEpoch = providerEpoch
    }
}

public enum SnapshotApplyDisposition: String, Sendable, Hashable, Codable {
    case persisted
    case active
    case idempotent
}

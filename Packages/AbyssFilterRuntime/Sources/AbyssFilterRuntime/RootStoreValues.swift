import AbyssIPC
import CryptoKit
import Foundation

public enum RootOwnership: Sendable, Hashable, Codable {
    case unclaimed
    case owned(uid: UInt32, lineageID: UUID, acceptedGenerationHighWater: UInt64)
    case resetting(oldUID: UInt32, targetLineageID: UUID)
    case replacingConfiguration(oldUID: UInt32, targetLineageID: UUID)
}

struct OwnershipFile: Sendable, Codable {
    static let schemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let ownership: RootOwnership
    let checksum: Data

    static func make(_ ownership: RootOwnership) throws -> OwnershipFile {
        let bytes = try checksumEncoder.encode(ownership)
        return OwnershipFile(
            schemaVersion: schemaVersion,
            ownership: ownership,
            checksum: Data(SHA256.hash(data: bytes))
        )
    }

    func validated() throws -> RootOwnership {
        guard schemaVersion == Self.schemaVersion else { throw RootPolicyStoreError.incompatibleSchema }
        let bytes = try Self.checksumEncoder.encode(ownership)
        guard Data(SHA256.hash(data: bytes)) == checksum else { throw RootPolicyStoreError.corruptOwnership }
        return ownership
    }

    private static var checksumEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

struct PolicySlot: Sendable, Codable {
    static let schemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let ownerUID: UInt32
    let lineageID: UUID
    let generation: UInt64
    let hash: Data
    let artifactBytes: Data

    init(ownerUID: UInt32, artifact: PolicyArtifact, payload: CompiledPolicyPayload) {
        self.schemaVersion = Self.schemaVersion
        self.ownerUID = ownerUID
        self.lineageID = payload.lineageID
        self.generation = payload.generation
        self.hash = artifact.hash
        self.artifactBytes = artifact.bytes
    }

    func validated() throws -> (PolicyArtifact, CompiledPolicyPayload) {
        guard schemaVersion == Self.schemaVersion else { throw RootPolicyStoreError.incompatibleSchema }
        let artifact = try PolicyArtifact(bytes: artifactBytes, hash: hash)
        let payload = try artifact.decode()
        guard payload.lineageID == lineageID, payload.generation == generation,
              payload.authorizedUID == ownerUID else { throw RootPolicyStoreError.corruptSlot }
        return (artifact, payload)
    }
}

struct SlotIndex: Sendable, Codable {
    static let schemaVersion: UInt16 = 1

    let schemaVersion: UInt16
    let currentSlot: String
    let generation: UInt64
    let hash: Data
}

public struct RecoveredPolicy: Sendable, Hashable {
    public let tuple: PolicyTuple
    public let artifact: PolicyArtifact
    public let payload: CompiledPolicyPayload
    public let recoveredAfterLostAcknowledgement: Bool
}

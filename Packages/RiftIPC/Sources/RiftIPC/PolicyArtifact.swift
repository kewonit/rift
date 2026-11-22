import RiftCore
import CryptoKit
import Foundation

public enum PolicyArtifactError: Error, Sendable, Equatable {
    case unsupportedSchema(UInt16)
    case invalidGeneration
    case tooLarge(Int)
    case hashMismatch
    case invalidHashLength(Int)
    case nonCanonicalEncoding
    case invalidOperationMode
    case excessiveRuleCount(Int)
    case excessiveGroupCount(Int)
    case nonCanonicalOrdering
}

public struct PolicyCompatibility: Sendable, Hashable, Codable {
    public let minimumAppProtocol: ProtocolVersion
    public let minimumExtensionProtocol: ProtocolVersion

    public init(
        minimumAppProtocol: ProtocolVersion = .baseline,
        minimumExtensionProtocol: ProtocolVersion = .baseline
    ) {
        self.minimumAppProtocol = minimumAppProtocol
        self.minimumExtensionProtocol = minimumExtensionProtocol
    }

    /// The oldest extension protocol that can decode `rules`. Policies with
    /// nothing new keep the baseline, so their bytes don't change.
    public static func minimumExtensionProtocol(
        for rules: [Rule],
        unansweredAlerts: UnansweredAlertPolicy? = nil
    ) -> ProtocolVersion {
        if unansweredAlerts != nil || rules.contains(where: \.usesExtendedPolicy) {
            return .extendedPolicy
        }
        return rules.contains(where: \.hasInternationalName) ? .internationalNames : .baseline
    }

    func raisingExtensionMinimum(to version: ProtocolVersion) -> PolicyCompatibility {
        guard version.major == minimumExtensionProtocol.major,
              version.minor > minimumExtensionProtocol.minor else { return self }
        return PolicyCompatibility(
            minimumAppProtocol: minimumAppProtocol,
            minimumExtensionProtocol: version
        )
    }
}

private extension Rule {
    var hasInternationalName: Bool {
        let names: [DomainName]
        switch destination {
        case .exactHostnameSet(let values), .domainSet(let values): names = values
        case .ipSet, .endpointClass, .anyEndpoint: return false
        }
        return names.contains { $0.ascii.split(separator: ".").contains { $0.hasPrefix("xn--") } }
    }
}

public struct CompiledPolicyPayload: Sendable, Hashable, Codable {
    public static let currentSchemaVersion: UInt16 = 1
    public static let maximumRuleCount = 100_000
    public static let maximumEnabledGroupCount = 10_000

    public let schemaVersion: UInt16
    public let lineageID: UUID
    public let generation: UInt64
    public let authorizedUID: UInt32
    public let compatibility: PolicyCompatibility
    public let createdAt: Date
    public let operationMode: OperationMode
    public let activeProfileID: UUID?
    public let enabledLocalGroupIDs: [UUID]
    public let rules: [Rule]
    /// Nil keeps the fixed wait and Allow of earlier builds, and leaves the
    /// policy's bytes as they were.
    public let unansweredAlerts: UnansweredAlertPolicy?

    public init(
        lineageID: UUID,
        generation: UInt64,
        authorizedUID: UInt32,
        compatibility: PolicyCompatibility = PolicyCompatibility(),
        createdAt: Date,
        operationMode: OperationMode,
        activeProfileID: UUID?,
        enabledLocalGroupIDs: Set<UUID>,
        rules: [Rule],
        unansweredAlerts: UnansweredAlertPolicy? = nil
    ) throws {
        guard generation > 0 else { throw PolicyArtifactError.invalidGeneration }
        guard operationMode != .degradedFallback else {
            throw PolicyArtifactError.invalidOperationMode
        }
        guard rules.count <= Self.maximumRuleCount else {
            throw PolicyArtifactError.excessiveRuleCount(rules.count)
        }
        guard enabledLocalGroupIDs.count <= Self.maximumEnabledGroupCount else {
            throw PolicyArtifactError.excessiveGroupCount(enabledLocalGroupIDs.count)
        }
        _ = try PolicySnapshot(lineageID: lineageID, generation: generation, rules: rules)
        self.schemaVersion = Self.currentSchemaVersion
        self.lineageID = lineageID
        self.generation = generation
        self.authorizedUID = authorizedUID
        self.compatibility = compatibility.raisingExtensionMinimum(
            to: PolicyCompatibility.minimumExtensionProtocol(
                for: rules,
                unansweredAlerts: unansweredAlerts
            )
        )
        self.createdAt = createdAt
        self.operationMode = operationMode
        self.activeProfileID = activeProfileID
        self.enabledLocalGroupIDs = enabledLocalGroupIDs.sorted { $0.uuidString < $1.uuidString }
        self.rules = rules.sorted { $0.id.uuidString < $1.id.uuidString }
        self.unansweredAlerts = unansweredAlerts
    }

    public func validated() throws -> CompiledPolicyPayload {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PolicyArtifactError.unsupportedSchema(schemaVersion)
        }
        guard generation > 0 else { throw PolicyArtifactError.invalidGeneration }
        guard operationMode != .degradedFallback else {
            throw PolicyArtifactError.invalidOperationMode
        }
        guard rules.count <= Self.maximumRuleCount else {
            throw PolicyArtifactError.excessiveRuleCount(rules.count)
        }
        guard enabledLocalGroupIDs.count <= Self.maximumEnabledGroupCount else {
            throw PolicyArtifactError.excessiveGroupCount(enabledLocalGroupIDs.count)
        }
        guard enabledLocalGroupIDs == Array(Set(enabledLocalGroupIDs)).sorted(by: {
            $0.uuidString < $1.uuidString
        }), rules == rules.sorted(by: { $0.id.uuidString < $1.id.uuidString }) else {
            throw PolicyArtifactError.nonCanonicalOrdering
        }
        _ = try PolicySnapshot(lineageID: lineageID, generation: generation, rules: rules)
        return self
    }
}

public struct PolicyArtifact: Sendable, Hashable {
    public static let maximumByteCount = 16 * 1_024 * 1_024

    public let bytes: Data
    public let hash: Data

    public init(bytes: Data, hash: Data) throws {
        guard bytes.count <= Self.maximumByteCount else {
            throw PolicyArtifactError.tooLarge(bytes.count)
        }
        guard hash.count == SHA256.Digest.byteCount else {
            throw PolicyArtifactError.invalidHashLength(hash.count)
        }
        guard Data(SHA256.hash(data: bytes)) == hash else {
            throw PolicyArtifactError.hashMismatch
        }
        self.bytes = bytes
        self.hash = hash
    }

    public static func compile(_ payload: CompiledPolicyPayload) throws -> PolicyArtifact {
        let encoder = CanonicalPolicyJSON.encoder()
        let bytes = try encoder.encode(payload.validated())
        guard bytes.count <= maximumByteCount else {
            throw PolicyArtifactError.tooLarge(bytes.count)
        }
        return try PolicyArtifact(bytes: bytes, hash: Data(SHA256.hash(data: bytes)))
    }

    public func decode() throws -> CompiledPolicyPayload {
        guard Data(SHA256.hash(data: bytes)) == hash else {
            throw PolicyArtifactError.hashMismatch
        }
        let payload = try CanonicalPolicyJSON.decoder()
            .decode(CompiledPolicyPayload.self, from: bytes)
            .validated()
        guard try CanonicalPolicyJSON.encoder().encode(payload) == bytes else {
            throw PolicyArtifactError.nonCanonicalEncoding
        }
        return payload
    }
}

public extension Data {
    var riftHexString: String { map { String(format: "%02x", $0) }.joined() }
}

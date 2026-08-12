import Foundation

public enum PolicySnapshotError: Error, Sendable, Equatable {
    case unsupportedSchemaVersion(UInt16)
    case duplicateRuleID(UUID)
    case mismatchedRuleLineage(ruleID: UUID, expected: UUID, actual: UUID)
    case generationZero
}

public struct PolicySnapshot: Sendable, Hashable, Codable {
    public static let currentSchemaVersion: UInt16 = 1

    public let schemaVersion: UInt16
    public let lineageID: UUID
    public let generation: UInt64
    public let rules: [Rule]

    public init(lineageID: UUID, generation: UInt64, rules: [Rule]) throws {
        guard generation > 0 else { throw PolicySnapshotError.generationZero }
        try Self.validate(rules, lineageID: lineageID)
        schemaVersion = Self.currentSchemaVersion
        self.lineageID = lineageID
        self.generation = generation
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(UInt16.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw PolicySnapshotError.unsupportedSchemaVersion(schemaVersion)
        }
        let lineageID = try container.decode(UUID.self, forKey: .lineageID)
        let generation = try container.decode(UInt64.self, forKey: .generation)
        guard generation > 0 else { throw PolicySnapshotError.generationZero }
        let rules = try container.decode([Rule].self, forKey: .rules)
        try Self.validate(rules, lineageID: lineageID)
        self.schemaVersion = schemaVersion
        self.lineageID = lineageID
        self.generation = generation
        self.rules = rules
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(lineageID, forKey: .lineageID)
        try container.encode(generation, forKey: .generation)
        try container.encode(rules, forKey: .rules)
    }

    private static func validate(_ rules: [Rule], lineageID: UUID) throws {
        var identifiers: Set<UUID> = []
        for rule in rules {
            guard identifiers.insert(rule.id).inserted else {
                throw PolicySnapshotError.duplicateRuleID(rule.id)
            }
            guard rule.lineageID == lineageID else {
                throw PolicySnapshotError.mismatchedRuleLineage(
                    ruleID: rule.id,
                    expected: lineageID,
                    actual: rule.lineageID
                )
            }
            try rule.validateStoredRepresentation()
        }
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case lineageID
        case generation
        case rules
    }
}

public enum CanonicalPolicyJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

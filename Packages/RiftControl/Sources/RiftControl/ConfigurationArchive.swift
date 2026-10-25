import RiftCore
import CryptoKit
import Foundation

public struct ConfigurationArchivePayload: Sendable, Hashable, Codable {
    public let baseOperationMode: OperationMode
    public let activeProfileID: UUID?
    public let rules: [Rule]
    public let localGroups: [LocalRuleGroup]
    public let profiles: [PolicyProfile]
    public let blocklists: [BlocklistSource]
    public let disabledBlocklistEntries: [BlocklistEntry]

    public init(
        baseOperationMode: OperationMode,
        activeProfileID: UUID?,
        rules: [Rule],
        localGroups: [LocalRuleGroup],
        profiles: [PolicyProfile],
        blocklists: [BlocklistSource],
        disabledBlocklistEntries: [BlocklistEntry] = []
    ) {
        self.baseOperationMode = baseOperationMode
        self.activeProfileID = activeProfileID
        self.rules = rules
        self.localGroups = localGroups
        self.profiles = profiles
        self.blocklists = blocklists
        self.disabledBlocklistEntries = disabledBlocklistEntries
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        baseOperationMode = try values.decode(OperationMode.self, forKey: .baseOperationMode)
        activeProfileID = try values.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        rules = try values.decode([Rule].self, forKey: .rules)
        localGroups = try values.decode([LocalRuleGroup].self, forKey: .localGroups)
        profiles = try values.decode([PolicyProfile].self, forKey: .profiles)
        blocklists = try values.decode([BlocklistSource].self, forKey: .blocklists)
        disabledBlocklistEntries = try values.decodeIfPresent(
            [BlocklistEntry].self, forKey: .disabledBlocklistEntries
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case baseOperationMode, activeProfileID, rules, localGroups, profiles, blocklists
        case disabledBlocklistEntries
    }
}

public struct ConfigurationArchive: Sendable, Hashable, Codable {
    public static let schemaVersion: UInt16 = 3
    public static let maximumBytes = 16 * 1_024 * 1_024

    public let schemaVersion: UInt16
    public let appVersion: String
    public let exportedAt: Date
    public let counts: ConfigurationArchiveCounts
    public let featureFlags: [String]
    public let payload: ConfigurationArchivePayload
    public let checksum: Data
}

public struct ConfigurationArchiveCounts: Sendable, Hashable, Codable {
    public let rules: Int
    public let localGroups: Int
    public let profiles: Int
    public let blocklists: Int
}

public enum ConfigurationArchiveError: Error, Sendable, Equatable {
    case oversized, unsupportedSchema, checksumMismatch
    case duplicateRule, duplicateGroup, duplicateProfile, duplicateBlocklist, invalidRelationship
    case countMismatch, invalidFeatureFlags, excessiveCount, excessiveNesting, invalidShape
    case invalidDefinition, protectedSource
}

public enum ConfigurationArchiveCodec {
    public static func export(
        draft: PolicyConfigurationDraft,
        appVersion: String,
        now: Date
    ) throws -> Data {
        try PolicyConfigurationValidator.validate(draft)
        let payload = ConfigurationArchivePayload(
            baseOperationMode: draft.baseOperationMode,
            activeProfileID: draft.activeProfileID,
            rules: draft.rules,
            localGroups: draft.localGroups,
            profiles: draft.profiles,
            blocklists: draft.blocklists,
            disabledBlocklistEntries: draft.disabledBlocklistEntries.sorted()
        )
        let checksum = Data(SHA256.hash(data: try encoder.encode(payload)))
        let archive = ConfigurationArchive(
            schemaVersion: ConfigurationArchive.schemaVersion,
            appVersion: String(appVersion.prefix(64)), exportedAt: now,
            counts: counts(payload),
            featureFlags: [
                "blocklistEntryOverrides", "blocklists", "localGroups", "profiles", "reviewState",
            ],
            payload: payload, checksum: checksum
        )
        let bytes = try encoder.encode(archive)
        guard bytes.count <= ConfigurationArchive.maximumBytes else {
            throw ConfigurationArchiveError.oversized
        }
        return bytes
    }

    public static func decode(_ data: Data) throws -> ConfigurationArchivePayload {
        guard data.count <= ConfigurationArchive.maximumBytes else {
            throw ConfigurationArchiveError.oversized
        }
        let encodedVersion = try schemaVersion(in: data)
        if encodedVersion == 2 { return try decodeVersion2(data) }
        guard encodedVersion == ConfigurationArchive.schemaVersion else {
            throw ConfigurationArchiveError.unsupportedSchema
        }
        try validateShape(data, schemaVersion: encodedVersion)
        let archive = try decoder.decode(ConfigurationArchive.self, from: data)
        try validateDecodedShape(data, archive: archive)
        guard Data(SHA256.hash(data: try encoder.encode(archive.payload))) == archive.checksum else {
            throw ConfigurationArchiveError.checksumMismatch
        }
        guard archive.counts == counts(archive.payload) else {
            throw ConfigurationArchiveError.countMismatch
        }
        let knownFlags = Set([
            "blocklistEntryOverrides", "blocklists", "localGroups", "profiles", "reviewState",
        ])
        guard Set(archive.featureFlags).count == archive.featureFlags.count,
              Set(archive.featureFlags) == knownFlags,
              archive.appVersion.unicodeScalars.count <= 64 else {
            throw ConfigurationArchiveError.invalidFeatureFlags
        }
        try validate(archive.payload)
        return archive.payload
    }

    private static func validate(_ payload: ConfigurationArchivePayload) throws {
        guard payload.rules.count <= 100_000,
              payload.localGroups.count <= 10_000,
              payload.profiles.count <= 10_000,
              payload.blocklists.count <= 10_000,
              payload.disabledBlocklistEntries.count
                <= BlocklistEntryOverrides.maximumDisabledEntries else {
            throw ConfigurationArchiveError.excessiveCount
        }
        guard payload.baseOperationMode != .degradedFallback,
              payload.profiles.allSatisfy({ $0.operationModeOverride != .degradedFallback }) else {
            throw ConfigurationArchiveError.invalidDefinition
        }
        guard Set(payload.rules.map(\.id)).count == payload.rules.count else {
            throw ConfigurationArchiveError.duplicateRule
        }
        guard Set(payload.localGroups.map(\.id)).count == payload.localGroups.count else {
            throw ConfigurationArchiveError.duplicateGroup
        }
        guard Set(payload.profiles.map(\.id)).count == payload.profiles.count else {
            throw ConfigurationArchiveError.duplicateProfile
        }
        guard Set(payload.blocklists.map(\.id)).count == payload.blocklists.count else {
            throw ConfigurationArchiveError.duplicateBlocklist
        }
        let groups = Set(payload.localGroups.map(\.id))
        let profiles = Set(payload.profiles.map(\.id))
        let blocklists = Set(payload.blocklists.map(\.id))
        guard payload.activeProfileID.map(profiles.contains) ?? true,
              payload.rules.allSatisfy({ $0.localGroupID.map(groups.contains) ?? true }),
              payload.rules.allSatisfy({ $0.profileID.map(profiles.contains) ?? true }),
              payload.rules.allSatisfy({ rule in
                  guard case .blocklist(let sourceID) = rule.source else { return true }
                  return blocklists.contains(sourceID)
              }) else {
            throw ConfigurationArchiveError.invalidRelationship
        }
        guard payload.localGroups.allSatisfy({
            isCanonicalName($0.name)
                && $0.note.unicodeScalars.count <= PolicyLimits.maximumNotesScalars
        }), payload.profiles.allSatisfy({
            isCanonicalName($0.name)
                && ($0.symbolName?.unicodeScalars.count ?? 0) <= 64
        }), payload.blocklists.allSatisfy({ source in
            isCanonicalName(source.name)
        }) else {
            throw ConfigurationArchiveError.invalidDefinition
        }
        guard uniqueNames(payload.localGroups.map(\.name)),
              uniqueNames(payload.profiles.map(\.name)),
              uniqueNames(payload.blocklists.map(\.name)) else {
            throw ConfigurationArchiveError.invalidDefinition
        }
        for rule in payload.rules {
            try rule.validateStoredRepresentation()
            if case .specificUser = rule.owner {
                throw ConfigurationArchiveError.invalidDefinition
            }
            if case .feature = rule.source {
                throw ConfigurationArchiveError.protectedSource
            }
            if rule.flags.contains(.protected),
               !rule.flags.contains(.sourceManaged) {
                throw ConfigurationArchiveError.protectedSource
            }
        }
        do {
            try PolicyConfigurationValidator.validateBlocklistRules(
                rules: payload.rules,
                sources: payload.blocklists
            )
            let entries = try BlocklistEntryOverrides.allEntries(in: payload.rules)
            let disabled = Set(payload.disabledBlocklistEntries)
            guard disabled.count == payload.disabledBlocklistEntries.count,
                  payload.disabledBlocklistEntries == payload.disabledBlocklistEntries.sorted(),
                  disabled.isSubset(of: entries) else {
                throw ConfigurationArchiveError.invalidDefinition
            }
        } catch {
            throw ConfigurationArchiveError.invalidDefinition
        }
    }

    private static func isCanonicalName(_ value: String) -> Bool {
        guard let validated = try? PolicyDefinitionValidator.name(value) else { return false }
        return validated == value
    }

    private static func uniqueNames(_ values: [String]) -> Bool {
        let locale = Locale(identifier: "en_US_POSIX")
        let keys = values.map {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
        }
        return Set(keys).count == keys.count
    }

    private static func validateShape(_ data: Data, schemaVersion: UInt16) throws {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in data {
            if inString {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { inString = false }
                continue
            }
            if byte == 0x22 {
                inString = true
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                guard depth <= 64 else { throw ConfigurationArchiveError.excessiveNesting }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
                guard depth >= 0 else { throw ConfigurationArchiveError.invalidShape }
            }
        }
        guard depth == 0, !inString else { throw ConfigurationArchiveError.invalidShape }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set([
                  "schemaVersion", "appVersion", "exportedAt", "counts",
                  "featureFlags", "payload", "checksum",
              ]),
              let counts = object["counts"] as? [String: Any],
              Set(counts.keys) == Set(["rules", "localGroups", "profiles", "blocklists"]),
              let payload = object["payload"] as? [String: Any] else {
            throw ConfigurationArchiveError.invalidShape
        }
        var requiredPayloadKeys = Set([
            "baseOperationMode", "rules", "localGroups", "profiles", "blocklists",
        ])
        if schemaVersion >= 3 { requiredPayloadKeys.insert("disabledBlocklistEntries") }
        let payloadKeys = Set(payload.keys)
        guard requiredPayloadKeys.isSubset(of: payloadKeys),
              payloadKeys.subtracting(["activeProfileID"]) == requiredPayloadKeys else {
            throw ConfigurationArchiveError.invalidShape
        }
    }

    private static func schemaVersion(in data: Data) throws -> UInt16 {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["schemaVersion"] as? NSNumber,
              value.uint64Value <= UInt64(UInt16.max) else {
            throw ConfigurationArchiveError.invalidShape
        }
        return UInt16(value.uint64Value)
    }

    private static func decodeVersion2(_ data: Data) throws -> ConfigurationArchivePayload {
        try validateShape(data, schemaVersion: 2)
        let archive = try decoder.decode(ConfigurationArchiveVersion2.self, from: data)
        let canonical = try encoder.encode(archive)
        let inputObject = try JSONSerialization.jsonObject(with: data)
        let canonicalObject = try JSONSerialization.jsonObject(with: canonical)
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard try JSONSerialization.data(withJSONObject: inputObject, options: options)
                == JSONSerialization.data(withJSONObject: canonicalObject, options: options),
              archive.schemaVersion == 2 else {
            throw ConfigurationArchiveError.invalidShape
        }
        guard Data(SHA256.hash(data: try encoder.encode(archive.payload))) == archive.checksum else {
            throw ConfigurationArchiveError.checksumMismatch
        }
        let payload = ConfigurationArchivePayload(
            baseOperationMode: archive.payload.baseOperationMode,
            activeProfileID: archive.payload.activeProfileID,
            rules: archive.payload.rules,
            localGroups: archive.payload.localGroups,
            profiles: archive.payload.profiles,
            blocklists: archive.payload.blocklists
        )
        guard archive.counts == counts(payload) else {
            throw ConfigurationArchiveError.countMismatch
        }
        let flags = Set(["blocklists", "localGroups", "profiles", "reviewState"])
        guard Set(archive.featureFlags).count == archive.featureFlags.count,
              Set(archive.featureFlags) == flags,
              archive.appVersion.unicodeScalars.count <= 64 else {
            throw ConfigurationArchiveError.invalidFeatureFlags
        }
        try validate(payload)
        return payload
    }

    private static func validateDecodedShape(
        _ data: Data,
        archive: ConfigurationArchive
    ) throws {
        let canonical = try encoder.encode(archive)
        let inputObject = try JSONSerialization.jsonObject(with: data)
        let canonicalObject = try JSONSerialization.jsonObject(with: canonical)
        let options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        guard try JSONSerialization.data(withJSONObject: inputObject, options: options)
            == JSONSerialization.data(withJSONObject: canonicalObject, options: options) else {
            throw ConfigurationArchiveError.invalidShape
        }
    }

    private static func counts(_ payload: ConfigurationArchivePayload) -> ConfigurationArchiveCounts {
        ConfigurationArchiveCounts(
            rules: payload.rules.count,
            localGroups: payload.localGroups.count,
            profiles: payload.profiles.count,
            blocklists: payload.blocklists.count
        )
    }

    private static var encoder: JSONEncoder { CanonicalPolicyJSON.encoder() }
    private static var decoder: JSONDecoder { CanonicalPolicyJSON.decoder() }
}

private struct ConfigurationArchivePayloadVersion2: Codable {
    let baseOperationMode: OperationMode
    let activeProfileID: UUID?
    let rules: [Rule]
    let localGroups: [LocalRuleGroup]
    let profiles: [PolicyProfile]
    let blocklists: [BlocklistSource]
}

private struct ConfigurationArchiveVersion2: Codable {
    let schemaVersion: UInt16
    let appVersion: String
    let exportedAt: Date
    let counts: ConfigurationArchiveCounts
    let featureFlags: [String]
    let payload: ConfigurationArchivePayloadVersion2
    let checksum: Data
}

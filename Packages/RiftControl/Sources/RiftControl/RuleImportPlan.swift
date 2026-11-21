import Foundation
import RiftCore

/// Adds the rules from an exported file to the current configuration without
/// replacing anything.
///
/// Every imported rule is a new rule, marked unreviewed so it's easy to find
/// and check. Rules you already have are skipped. A rule that belongs to a
/// group or profile goes into the one with the same name, which is created if
/// it doesn't exist; a new profile isn't switched on. Blocklist exceptions and
/// rules for system processes arrive turned off, because a shared file
/// shouldn't be able to let blocklisted hosts through or change what system
/// services may do without a closer look.
public struct RuleImportPlan: Sendable, Equatable {
    public let rules: [Rule]
    public let newGroups: [LocalRuleGroup]
    public let newProfiles: [PolicyProfile]
    /// Rules that match one you already have.
    public let duplicates: Int
    /// Rules that have expired, or that Rift manages, such as blocklist rules.
    public let skipped: Int
    /// Blocklist exceptions and system-process rules, added turned off.
    public let turnedOff: Int

    public static func make(
        _ payload: ConfigurationArchivePayload,
        into draft: PolicyConfigurationDraft,
        now: Date
    ) throws -> RuleImportPlan {
        let candidates = payload.rules.filter {
            ConfigurationArchiveCodec.isShareable($0) && ($0.expiresAt.map { $0 > now } ?? true)
        }
        var groups = NameMap(existing: draft.localGroups.map { ($0.id, $0.name) })
        var profiles = NameMap(existing: draft.profiles.map { ($0.id, $0.name) })
        var newGroups: [LocalRuleGroup] = []
        var newProfiles: [PolicyProfile] = []
        let sourceGroups = Dictionary(uniqueKeysWithValues: payload.localGroups.map { ($0.id, $0) })
        let sourceProfiles = Dictionary(uniqueKeysWithValues: payload.profiles.map { ($0.id, $0) })
        var known = Set(draft.rules.map(Signature.init))
        var rules: [Rule] = []
        var duplicates = 0
        var turnedOff = 0
        for source in candidates {
            let groupID = source.localGroupID.flatMap { sourceGroups[$0] }.map { group in
                groups.id(for: group.name) {
                    let created = LocalRuleGroup(
                        id: UUID(), name: group.name, note: group.note,
                        isEnabled: group.isEnabled, createdAt: now, modifiedAt: now
                    )
                    newGroups.append(created)
                    return created.id
                }
            }
            let profileID = source.profileID.flatMap { sourceProfiles[$0] }.map { profile in
                profiles.id(for: profile.name) {
                    let created = PolicyProfile(
                        id: UUID(), name: profile.name, symbolName: profile.symbolName,
                        operationModeOverride: profile.operationModeOverride,
                        createdAt: now, modifiedAt: now
                    )
                    newProfiles.append(created)
                    return created.id
                }
            }
            let needsLook = source.priority == .elevatedUser || source.owner == .system
            let rule = try Rule(
                id: UUID(), lineageID: draft.lineageID, revision: 1,
                action: source.action, priority: source.priority, process: source.process,
                destination: source.destination, transportProtocol: source.transportProtocol,
                port: source.port, direction: source.direction, owner: source.owner,
                profileID: profileID, localGroupID: groupID,
                expiresAt: source.expiresAt, isEnabled: source.isEnabled && !needsLook, flags: [],
                reviewState: .unreviewed, source: .imported, notes: source.notes,
                createdAt: now, modifiedAt: now
            )
            guard known.insert(Signature(rule)).inserted else {
                duplicates += 1
                continue
            }
            if needsLook, source.isEnabled { turnedOff += 1 }
            rules.append(rule)
        }
        // A group or profile is only worth creating for a rule that's added.
        let usedGroups = Set(rules.compactMap(\.localGroupID))
        let usedProfiles = Set(rules.compactMap(\.profileID))
        return RuleImportPlan(
            rules: rules,
            newGroups: newGroups.filter { usedGroups.contains($0.id) },
            newProfiles: newProfiles.filter { usedProfiles.contains($0.id) },
            duplicates: duplicates,
            skipped: payload.rules.count - candidates.count,
            turnedOff: turnedOff
        )
    }

    public func applied(to draft: PolicyConfigurationDraft) -> PolicyConfigurationDraft {
        PolicyConfigurationDraft(
            lineageID: draft.lineageID,
            authorizedUID: draft.authorizedUID,
            operationMode: draft.operationMode,
            baseOperationMode: draft.baseOperationMode,
            activeProfileID: draft.activeProfileID,
            enabledLocalGroupIDs: draft.enabledLocalGroupIDs
                .union(newGroups.filter(\.isEnabled).map(\.id)),
            rules: draft.rules + rules,
            localGroups: draft.localGroups + newGroups,
            profiles: draft.profiles + newProfiles,
            blocklists: draft.blocklists,
            disabledBlocklistEntries: draft.disabledBlocklistEntries
        )
    }

    /// What the import will do, in a sentence or two.
    public var summary: String {
        var parts: [String] = []
        parts.append(rules.count == 1 ? "Adds 1 rule." : "Adds \(rules.count) rules.")
        let allows = rules.filter { $0.action == .filter(.allow) }.count
        if allows > 0 {
            parts.append(allows == 1 ? "1 of them allows connections." : "\(allows) of them allow connections.")
        }
        if turnedOff > 0 {
            parts.append(turnedOff == 1
                ? "1 blocklist exception or system-process rule is added turned off. Check it, then turn it on in Rules."
                : "\(turnedOff) blocklist exceptions or system-process rules are added turned off. Check them, then turn them on in Rules.")
        }
        if duplicates > 0 {
            parts.append(duplicates == 1
                ? "1 rule you already have is skipped."
                : "\(duplicates) rules you already have are skipped.")
        }
        if skipped > 0 {
            parts.append(skipped == 1
                ? "1 expired or blocklist rule is skipped."
                : "\(skipped) expired or blocklist rules are skipped.")
        }
        let created = newGroups.map { "the group “\($0.name)”" }
            + newProfiles.map { "the profile “\($0.name)”" }
        if !created.isEmpty {
            parts.append("Creates \(ListFormatter.localizedString(byJoining: created)).")
        }
        if !rules.isEmpty {
            parts.append("New rules are marked unreviewed.")
        }
        return parts.joined(separator: " ")
    }

    /// The parts of a rule that decide what it does.
    private struct Signature: Hashable {
        let action: RuleAction
        let priority: RulePriority
        let process: ProcessCondition
        let destination: DestinationCondition
        let transport: ProtocolCondition
        let port: PortRange?
        let direction: DirectionCondition
        let owner: OwnerCondition
        let profileID: UUID?
        let localGroupID: UUID?
        let expiresAt: Date?

        init(_ rule: Rule) {
            action = rule.action
            priority = rule.priority
            process = rule.process
            destination = rule.destination
            transport = rule.transportProtocol
            port = rule.port
            direction = rule.direction
            owner = rule.owner
            profileID = rule.profileID
            localGroupID = rule.localGroupID
            expiresAt = rule.expiresAt
        }
    }

    /// Finds a group or profile by name, the way Rift compares names, or
    /// makes one.
    private struct NameMap {
        private var ids: [String: UUID] = [:]

        init(existing: [(UUID, String)]) {
            for (id, name) in existing { ids[Self.key(name)] = id }
        }

        mutating func id(for name: String, create: () -> UUID) -> UUID {
            if let id = ids[Self.key(name)] { return id }
            let id = create()
            ids[Self.key(name)] = id
            return id
        }

        private static func key(_ name: String) -> String {
            name.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        }
    }
}

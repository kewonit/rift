import Foundation
import RiftCore

/// A rule group Rift keeps up to date from a `.lsrules` file at a web
/// address the person entered. Unlike a blocklist it can hold allow rules,
/// so an update that adds one can't quietly let more through: unless the
/// person turns that off, a new allow rule stays off until they approve it.
public struct RuleGroupSubscription: Sendable, Hashable, Codable, Identifiable {
    /// The rule group this subscription keeps updated.
    public let id: UUID
    public let url: URL
    public var lastCheckedAt: Date?
    public var lastChangedAt: Date?
    /// Why the last check failed, in a sentence, or nil when it worked.
    public var lastFailure: String?
    public var entityTag: String?
    public var lastModified: String?
    /// Nil for daily, the default.
    public var interval: BlocklistUpdateInterval?
    /// Nil for on, the default: new allow rules from an update stay off.
    public var allowsNewAllowRules: Bool?
    /// Rules an update added turned off, waiting for the person to approve.
    public var pendingRuleIDs: [UUID]

    public var effectiveInterval: BlocklistUpdateInterval { interval ?? .daily }
    public var holdsNewAllowRules: Bool { allowsNewAllowRules != true }

    public init(
        id: UUID,
        url: URL,
        interval: BlocklistUpdateInterval? = nil,
        holdsNewAllowRules: Bool = true,
        lastCheckedAt: Date? = nil
    ) {
        self.id = id
        self.url = url
        self.interval = interval == .daily ? nil : interval
        self.allowsNewAllowRules = holdsNewAllowRules ? nil : true
        self.lastCheckedAt = lastCheckedAt
        self.lastChangedAt = lastCheckedAt
        self.pendingRuleIDs = []
    }

    public func isDue(now: Date) -> Bool {
        effectiveInterval.isDue(lastCheckedAt: lastCheckedAt, failed: lastFailure != nil, now: now)
    }

    /// Rules still waiting for approval: ones held before that are still in
    /// the group and still off, plus ones an update just held. A rule the
    /// person turned on or removed isn't waiting anymore.
    public mutating func notePending(held: [UUID] = [], groupRules: [Rule]) {
        let off = Set(groupRules.filter { !$0.isEnabled }.map(\.id))
        pendingRuleIDs = Set(pendingRuleIDs + held).intersection(off).sorted { $0.uuidString < $1.uuidString }
    }

    /// What a configuration archive keeps. Rules held for approval come back
    /// turned off, so a restore can't turn them on.
    public var archived: ArchivedRuleGroupSubscription {
        ArchivedRuleGroupSubscription(
            groupID: id, url: url, interval: interval, holdsNewAllowRules: holdsNewAllowRules
        )
    }

    public init(restoring archived: ArchivedRuleGroupSubscription) {
        self.init(
            id: archived.groupID, url: archived.url, interval: archived.interval,
            holdsNewAllowRules: archived.allowsNewAllowRules != true
        )
    }
}

/// A rule group subscription keeps its group's ID, address, how often it's
/// checked, and whether new allow rules wait for approval. Each optional is
/// nil for the default, so the archive stays as small as it can.
public struct ArchivedRuleGroupSubscription: Sendable, Hashable, Codable {
    public let groupID: UUID
    public let url: URL
    public let interval: BlocklistUpdateInterval?
    public let allowsNewAllowRules: Bool?

    public init(groupID: UUID, url: URL, interval: BlocklistUpdateInterval? = nil, holdsNewAllowRules: Bool = true) {
        self.groupID = groupID
        self.url = url
        self.interval = interval == .daily ? nil : interval
        self.allowsNewAllowRules = holdsNewAllowRules ? nil : true
    }
}

public enum RuleGroupSubscriptionError: Error, Sendable, Equatable {
    /// The file only blocks destinations, so it belongs in Blocklists.
    case onlyBlockedDestinations
    /// None of the file's rules can apply on this Mac.
    case noUsableRules
}

/// Folds a new version of a subscribed file into its group.
///
/// A rule that's in both versions stays exactly as it is, including whether
/// the person turned it off, so an update never undoes their choice. A rule
/// that's gone from the file is removed. A new rule is added as the file
/// says, except that a new allow rule is held off when the subscription
/// asks for that, and a high-priority rule, which can let blocklisted hosts
/// through, is always held off.
public struct RuleGroupSubscriptionMerge: Sendable, Equatable {
    public let rules: [Rule]
    public let added: Int
    public let removed: Int
    /// New rules added turned off until the person approves them.
    public let heldRuleIDs: [UUID]

    public var changed: Bool { added > 0 || removed > 0 }

    public static func merge(
        current: [Rule],
        incoming: [Rule],
        groupID: UUID,
        holdsNewAllowRules: Bool,
        isFirstVersion: Bool,
        now: Date
    ) throws -> RuleGroupSubscriptionMerge {
        let existing = Dictionary(current.map { (Key($0), $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<Key> = []
        var rules: [Rule] = []
        var added = 0
        var held: [UUID] = []
        for source in incoming {
            let key = Key(source)
            guard seen.insert(key).inserted else { continue }
            if let kept = existing[key] {
                rules.append(kept)
                continue
            }
            let allows = source.action == .filter(.allow)
            let hold = source.priority == .elevatedUser || (allows && holdsNewAllowRules && !isFirstVersion)
            let rule = try Rule(
                id: UUID(), lineageID: source.lineageID, revision: 1, action: source.action,
                priority: source.priority, process: source.process, destination: source.destination,
                transportProtocol: source.transportProtocol, port: source.port, direction: source.direction,
                owner: source.owner, localGroupID: groupID, isEnabled: source.isEnabled && !hold,
                reviewState: .unreviewed, source: .imported, notes: source.notes, createdAt: now, modifiedAt: now
            )
            if hold, source.isEnabled { held.append(rule.id) }
            rules.append(rule)
            added += 1
        }
        return RuleGroupSubscriptionMerge(
            rules: rules,
            added: added,
            removed: existing.keys.filter { !seen.contains($0) }.count,
            heldRuleIDs: held
        )
    }

    /// What an update did, in a sentence.
    public var summary: String {
        guard changed else { return "The rule group is up to date." }
        var parts = [
            added == 1 ? "1 rule added" : "\(added) rules added",
            removed == 1 ? "1 removed" : "\(removed) removed",
        ]
        if !heldRuleIDs.isEmpty {
            parts.append(heldRuleIDs.count == 1
                ? "1 new allow rule is off until you turn it on"
                : "\(heldRuleIDs.count) new allow rules are off until you turn them on")
        }
        return parts.joined(separator: ", ") + "."
    }

    /// The parts of a rule that decide what it does, so a rule that's in
    /// both versions of the file is recognized as the same rule.
    private struct Key: Hashable {
        let action: RuleAction
        let priority: RulePriority
        let process: ProcessCondition
        let destination: DestinationCondition
        let transport: ProtocolCondition
        let port: PortRange?
        let direction: DirectionCondition
        let owner: OwnerCondition

        init(_ rule: Rule) {
            action = rule.action
            priority = rule.priority
            process = rule.process
            destination = rule.destination
            transport = rule.transportProtocol
            port = rule.port
            direction = rule.direction
            owner = rule.owner
        }
    }
}

extension BlocklistUpdateInterval {
    /// Whether it's time to check again. A failed check is retried after an
    /// hour at most. A list checked only on request is never due.
    public func isDue(lastCheckedAt: Date?, failed: Bool, now: Date) -> Bool {
        guard let seconds else { return false }
        guard let lastCheckedAt else { return true }
        let wait = failed ? min(seconds, 60 * 60) : seconds
        return now.timeIntervalSince(lastCheckedAt) >= wait
    }
}

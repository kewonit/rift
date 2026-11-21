import Foundation
import RiftCore

/// Finds rules that can be deleted without changing any decision.
///
/// A rule is redundant when another rule with the same action and priority
/// applies whenever it does and covers everything it matches, and no rule
/// with a different action in the same category could match any of the same
/// connections at the same priority. Without such a rule, whatever decided
/// the connection after the deletion still gives the same result. The check
/// errs toward keeping rules: anything that might overlap counts as
/// overlapping, so a rule it calls redundant really is.
public enum RuleRedundancy {
    /// For each redundant rule, the rule that already does what it does.
    public static func redundantRules(in rules: [Rule], now: Date) -> [UUID: UUID] {
        let live = rules.filter { isLive($0, now: now) }
        var byIdentity: [ProcessIdentity: [Rule]] = [:]
        var anyProcess: [Rule] = []
        for rule in live {
            let identities = identities(of: rule.process)
            if identities.isEmpty { anyProcess.append(rule) }
            for identity in identities { byIdentity[identity, default: []].append(rule) }
        }
        // Rules only compete with rules of the same priority in the same
        // category, so only those can be conflicts.
        var competitors: [String: [Rule]] = [:]
        for rule in live { competitors[bucket(rule), default: []].append(rule) }
        var result: [UUID: UUID] = [:]
        for candidate in live where isAnalyzable(candidate) {
            var related = anyProcess
            for identity in identities(of: candidate.process) {
                related += byIdentity[identity] ?? []
            }
            guard let cover = related.first(where: {
                $0.id != candidate.id && covers($0, candidate, now: now)
                    && !(covers(candidate, $0, now: now) && isOlder(candidate, than: $0))
            }) else { continue }
            let conflicts = (competitors[bucket(candidate)] ?? []).contains { other in
                other.action != candidate.action && mayOverlap(other, candidate)
            }
            if !conflicts { result[candidate.id] = cover.id }
        }
        return result
    }

    private static func isLive(_ rule: Rule, now: Date) -> Bool {
        rule.isEnabled && (rule.expiresAt.map { $0 > now } ?? true)
    }

    /// Blocklist and protected rules can't be deleted here, so they're never
    /// reported, but they still count as covers and conflicts.
    private static func isAnalyzable(_ rule: Rule) -> Bool {
        !rule.flags.contains(.sourceManaged) && !rule.flags.contains(.protected)
    }

    /// Of two identical rules, the newer one is the copy.
    private static func isOlder(_ rule: Rule, than other: Rule) -> Bool {
        (rule.createdAt, rule.id.uuidString) < (other.createdAt, other.id.uuidString)
    }

    private static func bucket(_ rule: Rule) -> String {
        let category = switch rule.action {
        case .filter: "filter"
        case .notification: "notification"
        case .privacy: "privacy"
        }
        return "\(rule.priority)|\(category)"
    }

    // MARK: Coverage

    /// Whether `cover` applies whenever `rule` does and matches everything
    /// `rule` matches, with the same result.
    private static func covers(_ cover: Rule, _ rule: Rule, now: Date) -> Bool {
        cover.action == rule.action && cover.priority == rule.priority && cover.owner == rule.owner
            && (cover.profileID == nil || cover.profileID == rule.profileID)
            && (cover.localGroupID == nil || cover.localGroupID == rule.localGroupID)
            && lasts(cover, asLongAs: rule)
            && processCovers(cover.process, rule.process)
            && destinationCovers(cover.destination, rule.destination)
            && (cover.transportProtocol == .anySupportedProtocol
                || cover.transportProtocol == rule.transportProtocol)
            && portCovers(cover.port, rule.port)
            && (cover.direction == .bidirectional || cover.direction == rule.direction)
    }

    private static func lasts(_ cover: Rule, asLongAs rule: Rule) -> Bool {
        guard let coverEnd = cover.expiresAt else { return true }
        guard let ruleEnd = rule.expiresAt else { return false }
        return coverEnd >= ruleEnd
    }

    private static func identities(of condition: ProcessCondition) -> [ProcessIdentity] {
        switch condition {
        case .anyProcess: []
        case .exact(let identity): [identity]
        case .appViaHelper(let app, let helper): [app, helper]
        }
    }

    /// An exact identity matches a connection made by that process or for
    /// that app, so it covers any app-via-helper pair that includes it.
    private static func processCovers(_ cover: ProcessCondition, _ rule: ProcessCondition) -> Bool {
        switch (cover, rule) {
        case (.anyProcess, _): true
        case (.exact(let identity), .exact(let other)): identity == other
        case (.exact(let identity), .appViaHelper(let app, let helper)):
            identity == app || identity == helper
        case (.appViaHelper, .appViaHelper): cover == rule
        default: false
        }
    }

    private static func destinationCovers(
        _ cover: DestinationCondition,
        _ rule: DestinationCondition
    ) -> Bool {
        switch (cover, rule) {
        case (.anyEndpoint, _): true
        case (.ipSet(let outer), .ipSet(let inner)):
            inner.allSatisfy { interval in outer.contains { contains($0, interval) } }
        case (.exactHostnameSet(let outer), .exactHostnameSet(let inner)):
            Set(inner).isSubset(of: outer)
        case (.domainSet(let outer), .domainSet(let inner)),
             (.domainSet(let outer), .exactHostnameSet(let inner)):
            inner.allSatisfy { name in outer.contains { name.isEqualToOrSubdomain(of: $0) } }
        case (.endpointClass(let outer), .endpointClass(let inner)): outer == inner
        default: false
        }
    }

    private static func contains(_ outer: IPInterval, _ inner: IPInterval) -> Bool {
        outer.contains(inner.lowerBound) && outer.contains(inner.upperBound)
    }

    private static func portCovers(_ cover: PortRange?, _ rule: PortRange?) -> Bool {
        guard let cover else { return true }
        guard let rule else { return false }
        return cover.lowerBound <= rule.lowerBound && rule.upperBound <= cover.upperBound
    }

    // MARK: Overlap

    /// Whether some connection could match both rules while both apply.
    private static func mayOverlap(_ lhs: Rule, _ rhs: Rule) -> Bool {
        if let left = lhs.profileID, let right = rhs.profileID, left != right { return false }
        return processesMayOverlap(lhs.process, rhs.process)
            && ownersMayOverlap(lhs.owner, rhs.owner)
            && (lhs.transportProtocol == .anySupportedProtocol
                || rhs.transportProtocol == .anySupportedProtocol
                || lhs.transportProtocol == rhs.transportProtocol)
            && portsOverlap(lhs.port, rhs.port)
            && (lhs.direction == .bidirectional || rhs.direction == .bidirectional
                || lhs.direction == rhs.direction)
            && destinationsMayOverlap(lhs.destination, rhs.destination)
    }

    /// An exact identity matches the process or the app it acts for, so two
    /// different exact identities can match one connection, such as a tool
    /// started from Terminal. Only fixed app-and-helper pairs can differ.
    private static func processesMayOverlap(_ lhs: ProcessCondition, _ rhs: ProcessCondition) -> Bool {
        switch (lhs, rhs) {
        case (.appViaHelper, .appViaHelper): lhs == rhs
        case (.exact(let identity), .appViaHelper(let app, let helper)),
             (.appViaHelper(let app, let helper), .exact(let identity)):
            identity == app || identity == helper
        default: true
        }
    }

    private static func ownersMayOverlap(_ lhs: OwnerCondition, _ rhs: OwnerCondition) -> Bool {
        switch (lhs, rhs) {
        case (.system, .system): true
        case (.system, _), (_, .system): false
        default: true
        }
    }

    private static func portsOverlap(_ lhs: PortRange?, _ rhs: PortRange?) -> Bool {
        guard let lhs, let rhs else { return true }
        return lhs.lowerBound <= rhs.upperBound && rhs.lowerBound <= lhs.upperBound
    }

    /// A connection has both an address and, often, a name, so an address
    /// condition may overlap a name condition.
    private static func destinationsMayOverlap(
        _ lhs: DestinationCondition,
        _ rhs: DestinationCondition
    ) -> Bool {
        switch (lhs, rhs) {
        case (.ipSet(let left), .ipSet(let right)):
            left.contains { a in right.contains { b in
                a.lowerBound.family == b.lowerBound.family
                    && a.lowerBound <= b.upperBound && b.lowerBound <= a.upperBound
            } }
        case (.exactHostnameSet(let left), .exactHostnameSet(let right)):
            !Set(left).isDisjoint(with: right)
        case (.domainSet(let domains), .exactHostnameSet(let hosts)),
             (.exactHostnameSet(let hosts), .domainSet(let domains)):
            hosts.contains { host in domains.contains { host.isEqualToOrSubdomain(of: $0) } }
        case (.domainSet(let left), .domainSet(let right)):
            left.contains { a in right.contains { b in
                a.isEqualToOrSubdomain(of: b) || b.isEqualToOrSubdomain(of: a)
            } }
        default:
            true
        }
    }
}

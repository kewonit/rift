import Foundation
import RiftControl
import RiftCore

/// A subscribed `.lsrules` file, read and checked against this Mac, waiting
/// for the person to confirm.
struct PendingRuleGroupSubscription: Equatable {
    let url: URL
    let name: String
    let conversion: LSRulesConverter.Conversion
    let entityTag: String?
    let lastModified: String?

    var ruleCount: Int { conversion.payload.rules.count }

    /// What subscribing adds, in a sentence or two.
    var summary: String {
        let rules = conversion.payload.rules
        let allows = rules.filter { $0.action == .filter(.allow) }.count
        var parts = [rules.count == 1 ? "Adds 1 rule in a new group." : "Adds \(rules.count) rules in a new group."]
        if allows > 0 {
            parts.append(allows == 1 ? "1 of them allows connections." : "\(allows) of them allow connections.")
        }
        return (parts + conversion.notices).joined(separator: " ")
    }
}

extension ControlPlaneController {
    /// Reads a downloaded `.lsrules` file as a rule group for this Mac.
    func previewRuleGroup(_ data: Data, url: URL) async throws -> LSRulesConverter.Conversion {
        guard LSRulesFile.looksLikeRulesFile(data) else { throw BlocklistSubscriptionError.notAList }
        let file = try LSRulesFile.decode(data)
        guard let lineageID = try await repository?.currentConfiguration()?.lineageID else {
            throw ArchiveControllerError.missingConfiguration
        }
        let host = BlocklistSubscriptionAddress.host(of: url)
        let conversion = await Task.detached(priority: .userInitiated) {
            LSRulesConverter.convert(
                file, fileName: host, lineageID: lineageID,
                resolve: LSRulesIdentityResolver.resolve, now: Date()
            )
        }.value
        guard !conversion.payload.rules.isEmpty else {
            throw file.rules.isEmpty ? RuleGroupSubscriptionError.onlyBlockedDestinations
                : RuleGroupSubscriptionError.noUsableRules
        }
        return conversion
    }

    /// Adds a subscribed file's rules as a new group. Returns the group's ID.
    func createSubscribedGroup(
        _ pending: PendingRuleGroupSubscription
    ) async throws -> (ConfigurationMutationResult, UUID, held: [UUID]) {
        let groupID = UUID()
        var held: [UUID] = []
        let result = try await mutateConfiguration(kind: "subscribeRuleGroup") { draft in
            let now = Date()
            let source = pending.conversion.payload.localGroups.first
            let group = LocalRuleGroup(
                id: groupID, name: Self.uniqueGroupName(pending.name, in: draft), note: source?.note ?? "",
                isEnabled: true, createdAt: now, modifiedAt: now
            )
            let merge = try RuleGroupSubscriptionMerge.merge(
                current: [], incoming: pending.conversion.payload.rules, groupID: groupID,
                holdsNewAllowRules: true, isFirstVersion: true, now: now
            )
            held = merge.heldRuleIDs
            return Self.copy(
                draft,
                enabledGroups: draft.enabledLocalGroupIDs.union([groupID]),
                rules: draft.rules + merge.rules,
                groups: draft.localGroups + [group]
            )
        }
        return (result, groupID, held)
    }

    /// Replaces a subscribed group's rules with a new version of its file.
    /// Rules the person added to the group themselves are left alone.
    func updateSubscribedGroup(
        _ groupID: UUID,
        incoming: [Rule],
        holdsNewAllowRules: Bool
    ) async throws -> (merge: RuleGroupSubscriptionMerge, groupRules: [Rule]) {
        var outcome: RuleGroupSubscriptionMerge?
        var groupRules: [Rule] = []
        do {
            _ = try await mutateConfiguration(kind: "updateRuleGroup", change: .automatic) { draft in
                guard draft.localGroups.contains(where: { $0.id == groupID }) else {
                    throw RuleCommandError.unknownDefinition
                }
                let managed = { (rule: Rule) in rule.localGroupID == groupID && rule.source == .imported }
                let merge = try RuleGroupSubscriptionMerge.merge(
                    current: draft.rules.filter(managed), incoming: incoming, groupID: groupID,
                    holdsNewAllowRules: holdsNewAllowRules, isFirstVersion: false, now: Date()
                )
                outcome = merge
                groupRules = draft.rules.filter { $0.localGroupID == groupID && !managed($0) } + merge.rules
                // An update that changes nothing saves nothing.
                guard merge.changed else { throw RuleGroupUpdateUnchanged() }
                return Self.copy(draft, rules: draft.rules.filter { !managed($0) } + merge.rules)
            }
        } catch is RuleGroupUpdateUnchanged {}
        guard let outcome else { throw RuleCommandError.missingConfiguration }
        return (outcome, groupRules)
    }

    /// The rules of a group, to see which held ones are still waiting.
    func rules(inGroup groupID: UUID) async -> [Rule]? {
        guard let draft = try? await repository?.currentConfiguration(),
              draft.localGroups.contains(where: { $0.id == groupID }) else { return nil }
        return draft.rules.filter { $0.localGroupID == groupID }
    }

    private static func uniqueGroupName(_ name: String, in draft: PolicyConfigurationDraft) -> String {
        let base = (try? PolicyDefinitionValidator.name(name)) ?? "Subscribed rules"
        let existing = draft.localGroups.map { ($0.id, $0.name) }
        for number in 1...100 {
            let candidate = number == 1 ? base : "\(base.prefix(120)) \(number)"
            if (try? PolicyDefinitionValidator.rejectCollision(candidate, existing: existing)) != nil { return candidate }
        }
        return "\(base.prefix(90)) \(UUID().uuidString.prefix(8))"
    }
}

private struct RuleGroupUpdateUnchanged: Error {}

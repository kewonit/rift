import Foundation
import RiftCore

/// The conditions of a rule made from a connection.
public struct MonitorRuleTarget: Sendable, Hashable {
    public let process: ProcessCondition
    public let destination: DestinationCondition
    public let transport: ProtocolCondition
    public let port: PortRange?
    public let direction: DirectionCondition
    public let owner: OwnerCondition

    public init(
        process: ProcessCondition,
        destination: DestinationCondition,
        transport: ProtocolCondition,
        port: PortRange?,
        direction: DirectionCondition,
        owner: OwnerCondition
    ) {
        self.process = process
        self.destination = destination
        self.transport = transport
        self.port = port
        self.direction = direction
        self.owner = owner
    }

    public init(seed: MonitorExactRuleSeed) {
        self.init(
            process: seed.process, destination: seed.destination, transport: seed.transport,
            port: seed.port, direction: seed.direction, owner: seed.owner
        )
    }

    func describes(_ rule: Rule) -> Bool {
        rule.process == process && rule.destination == destination
            && rule.transportProtocol == transport && rule.port == port
            && rule.direction == direction && rule.owner == owner
    }
}

public enum MonitorRulePlanResult: Sendable, Equatable {
    /// Rules already give this result, so nothing needs saving.
    case alreadyDecided(ruleID: UUID?)
    case changed(rules: [Rule], affectedRuleIDs: Set<UUID>)
    /// Saving wouldn't change the result, because this rule would still decide.
    case overridden(by: UUID?)
    /// A permanent rule with the same conditions does the opposite. A
    /// temporary choice can't change it, because the permanent rule would be
    /// gone when the time runs out.
    case permanentRuleConflict(ruleID: UUID)
}

/// Works out how to make a connection allowed or blocked from now on.
///
/// Rules with the same conditions are flipped rather than added to, because a
/// new rule would tie with the old one and a block always wins a tie. Broader
/// rules are never edited, because that would change other traffic. A
/// temporary choice never edits a permanent rule, because the permanent rule
/// would end with it. The result is checked before saving, so Rift never
/// reports a change that won't happen.
public enum MonitorRulePlan {
    public static func plan(
        action: FilterAction,
        priority: RulePriority,
        target: MonitorRuleTarget,
        flow: FlowDescriptor,
        configuration: PolicyConfigurationDraft,
        expiresAt: Date? = nil,
        now: Date,
        makeRule: () throws -> Rule
    ) throws -> MonitorRulePlanResult {
        let scope = RuleWorkspaceQueryContext(configuration: configuration, now: now)
        let matching = configuration.rules.filter {
            target.describes($0) && isEditable($0) && scope.includes($0)
        }
        let wanted = RuleAction.filter(action)
        let temporary = expiresAt != nil
        // A temporary choice never edits a permanent rule.
        let permanent = temporary ? matching.filter { $0.expiresAt == nil } : []
        // A permanent rule that does the opposite blocks a temporary choice
        // only if it would still win; a higher-priority temporary rule beats it.
        if let conflict = permanent.first(where: {
            $0.action != wanted && rank($0.priority) >= rank(priority)
        }) {
            return .permanentRuleConflict(ruleID: conflict.id)
        }
        let editable = temporary ? matching.filter { $0.expiresAt != nil } : matching
        // A permanent rule that already does this, at a high enough priority,
        // covers the temporary choice. Temporary rules that disagree still flip,
        // because a block wins a tie.
        let covered = permanent.contains {
            $0.action == wanted && (priority == .normal || $0.priority == priority)
        }
        let needsChange = editable.filter {
            $0.action != wanted || (!covered && (
                (priority != .normal && $0.priority != priority) || $0.expiresAt != expiresAt
            ))
        }
        let addsRule = editable.isEmpty && !covered
        let ids = Set(needsChange.map(\.id))
        var proposed = try configuration.rules.map { rule in
            guard ids.contains(rule.id) else { return rule }
            return try RuleMutation.edited(
                rule,
                action: wanted,
                priority: priority == .normal ? rule.priority : priority,
                process: rule.process,
                destination: rule.destination,
                transport: rule.transportProtocol,
                port: rule.port,
                direction: rule.direction,
                owner: rule.owner,
                profileID: rule.profileID,
                localGroupID: rule.localGroupID,
                expiresAt: expiresAt,
                isEnabled: true,
                reviewState: .reviewed,
                note: rule.notes,
                now: now
            )
        }
        var affected = Set(editable.map(\.id))
        if addsRule {
            let rule = try makeRule()
            proposed.append(rule)
            affected.insert(rule.id)
        }
        let result = decision(for: flow, rules: proposed, configuration: configuration, now: now)
        guard result.filter.action == action else {
            return .overridden(by: result.filter.winningRuleID)
        }
        if !addsRule, needsChange.isEmpty {
            return .alreadyDecided(ruleID: result.filter.winningRuleID)
        }
        return .changed(rules: proposed, affectedRuleIDs: affected)
    }

    private static func rank(_ priority: RulePriority) -> Int {
        switch priority {
        case .normal: 0
        case .blocklistDeny: 1
        case .elevatedUser: 2
        }
    }

    private static func isEditable(_ rule: Rule) -> Bool {
        !rule.flags.contains(.protected) && !rule.flags.contains(.sourceManaged)
    }

    /// Pause Rules bypasses rules entirely, so rules are judged as they'd
    /// apply once they're switched back on.
    private static func decision(
        for flow: FlowDescriptor,
        rules: [Rule],
        configuration: PolicyConfigurationDraft,
        now: Date
    ) -> Decision {
        let context = MatchContext(
            activeProfileID: configuration.activeProfileID,
            enabledLocalGroupIDs: configuration.enabledLocalGroupIDs,
            authorizedUID: configuration.authorizedUID,
            policyTime: PolicyTime(now: now, expiryMetadata: .available(alreadyExpired: []))
        )
        let mode: OperationMode = configuration.operationMode == .filterOff
            ? .silentAllow : configuration.operationMode
        return CompiledRuleMatcher(rules: rules).decision(for: flow, context: context, mode: mode)
    }
}

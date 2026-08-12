import RiftCore
import Foundation

public enum RuleWorkspaceDropOperation: Sendable, Hashable {
    case move
    case copy
}

public enum RuleWorkspaceDropTarget: Sendable, Hashable {
    case localGroup(UUID)
    case profile(UUID)
}

public enum RuleWorkspaceDropError: Error, Sendable, Equatable {
    case emptySelection
    case duplicateRuleID(UUID)
    case missingRuleIDs(Set<UUID>)
    case noEligibleRules
    case noChanges
    case ruleLimitExceeded
    case stalePlan
    case unexpectedNewRuleIDs
    case invalidNewRuleIDs
}

public struct RuleWorkspaceDropPlan: Sendable, Equatable {
    public let operation: RuleWorkspaceDropOperation
    public let target: RuleWorkspaceDropTarget
    public let selectedRuleIDs: Set<UUID>
    public let affectedRuleIDs: Set<UUID>
    public let skippedRuleIDs: Set<UUID>
    public let unchangedRuleIDs: Set<UUID>
    private let expectedSelectedRules: [Rule]

    public init(
        rules: [Rule],
        selectedRuleIDs: Set<UUID>,
        target: RuleWorkspaceDropTarget,
        operation: RuleWorkspaceDropOperation
    ) throws {
        guard !selectedRuleIDs.isEmpty else {
            throw RuleWorkspaceDropError.emptySelection
        }
        let indexed = try Self.index(rules)
        let missing = selectedRuleIDs.subtracting(indexed.keys)
        guard missing.isEmpty else {
            throw RuleWorkspaceDropError.missingRuleIDs(missing)
        }

        var affected: Set<UUID> = []
        var skipped: Set<UUID> = []
        var unchanged: Set<UUID> = []
        for rule in rules where selectedRuleIDs.contains(rule.id) {
            if rule.flags.contains(.protected) || rule.flags.contains(.sourceManaged) {
                skipped.insert(rule.id)
                continue
            }
            if operation == .move, Self.alreadyAssigned(rule, to: target) {
                unchanged.insert(rule.id)
            } else {
                affected.insert(rule.id)
            }
        }
        guard !affected.isEmpty else {
            throw skipped.count == selectedRuleIDs.count
                ? RuleWorkspaceDropError.noEligibleRules
                : RuleWorkspaceDropError.noChanges
        }
        if operation == .copy,
           rules.count > PolicyConfigurationValidator.maximumRules - affected.count {
            throw RuleWorkspaceDropError.ruleLimitExceeded
        }

        self.operation = operation
        self.target = target
        self.selectedRuleIDs = selectedRuleIDs
        affectedRuleIDs = affected
        skippedRuleIDs = skipped
        unchangedRuleIDs = unchanged
        expectedSelectedRules = rules.filter { selectedRuleIDs.contains($0.id) }
    }

    public func applying(
        to rules: [Rule],
        newRuleIDs: [UUID],
        now: Date
    ) throws -> [Rule] {
        let current: Self
        do {
            current = try Self(
                rules: rules,
                selectedRuleIDs: selectedRuleIDs,
                target: target,
                operation: operation
            )
        } catch {
            throw RuleWorkspaceDropError.stalePlan
        }
        guard current == self else { throw RuleWorkspaceDropError.stalePlan }

        switch operation {
        case .move:
            guard newRuleIDs.isEmpty else {
                throw RuleWorkspaceDropError.unexpectedNewRuleIDs
            }
            return try rules.map { rule in
                guard affectedRuleIDs.contains(rule.id) else { return rule }
                let assignment = Self.assignment(for: rule, target: target)
                return try RuleMutation.assigned(
                    rule,
                    profileID: assignment.profileID,
                    localGroupID: assignment.localGroupID,
                    now: now
                )
            }
        case .copy:
            guard newRuleIDs.count == affectedRuleIDs.count,
                  Set(newRuleIDs).count == newRuleIDs.count,
                  Set(newRuleIDs).isDisjoint(with: Set(rules.map(\.id))) else {
                throw RuleWorkspaceDropError.invalidNewRuleIDs
            }
            var iterator = newRuleIDs.makeIterator()
            var copies: [Rule] = []
            copies.reserveCapacity(affectedRuleIDs.count)
            for rule in rules where affectedRuleIDs.contains(rule.id) {
                guard let newID = iterator.next() else {
                    throw RuleWorkspaceDropError.invalidNewRuleIDs
                }
                let assignment = Self.assignment(for: rule, target: target)
                copies.append(try RuleMutation.duplicate(
                    rule,
                    id: newID,
                    profileID: assignment.profileID,
                    localGroupID: assignment.localGroupID,
                    now: now
                ))
            }
            return rules + copies
        }
    }

    private static func index(_ rules: [Rule]) throws -> [UUID: Rule] {
        var result: [UUID: Rule] = [:]
        result.reserveCapacity(rules.count)
        for rule in rules {
            guard result.updateValue(rule, forKey: rule.id) == nil else {
                throw RuleWorkspaceDropError.duplicateRuleID(rule.id)
            }
        }
        return result
    }

    private static func alreadyAssigned(
        _ rule: Rule,
        to target: RuleWorkspaceDropTarget
    ) -> Bool {
        switch target {
        case .localGroup(let id): rule.localGroupID == id
        case .profile(let id): rule.profileID == id
        }
    }

    private static func assignment(
        for rule: Rule,
        target: RuleWorkspaceDropTarget
    ) -> (profileID: UUID?, localGroupID: UUID?) {
        switch target {
        case .localGroup(let id): (rule.profileID, id)
        case .profile(let id): (id, rule.localGroupID)
        }
    }
}

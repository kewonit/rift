import AbyssCore
import Foundation

public enum RuleWorkspaceUndoError: Error, Sendable, Equatable {
    case noChanges
    case duplicateRuleID(UUID)
    case generationConflict
    case ruleChanged(UUID)
    case protectedRule(UUID)
    case sourceManagedRule(UUID)
    case lineageMismatch
    case revisionOverflow(UUID)
}

public struct RuleWorkspaceUndoPlan: Sendable, Equatable {
    private struct Change: Sendable, Equatable {
        let id: UUID
        let target: Rule?
        let expected: Rule?
    }

    public let expectedGeneration: UInt64
    public let affectedRuleIDs: Set<UUID>
    private let changes: [Change]
    private let targetOrder: [UUID]

    public init(
        beforeMutation: [Rule],
        afterMutation: [Rule],
        expectedGeneration: UInt64
    ) throws {
        let before = try Self.index(beforeMutation)
        let after = try Self.index(afterMutation)
        let lineages = Set((beforeMutation + afterMutation).map(\.lineageID))
        guard lineages.count <= 1 else { throw RuleWorkspaceUndoError.lineageMismatch }

        let orderedIDs = beforeMutation.map(\.id)
            + afterMutation.lazy.map(\.id).filter { before[$0] == nil }
        let changes = orderedIDs.compactMap { id -> Change? in
            guard before[id] != after[id] else { return nil }
            return Change(id: id, target: before[id], expected: after[id])
        }
        guard !changes.isEmpty else { throw RuleWorkspaceUndoError.noChanges }
        for change in changes {
            try Self.validateInteractive(change.target ?? change.expected, id: change.id)
            try Self.validateInteractive(change.expected ?? change.target, id: change.id)
        }

        self.expectedGeneration = expectedGeneration
        affectedRuleIDs = Set(changes.map(\.id))
        self.changes = changes
        targetOrder = beforeMutation.map(\.id)
    }

    public func restoring(
        currentRules: [Rule],
        currentGeneration: UInt64,
        now: Date
    ) throws -> [Rule] {
        guard currentGeneration == expectedGeneration else {
            throw RuleWorkspaceUndoError.generationConflict
        }
        var current = try Self.index(currentRules)
        for change in changes {
            guard current[change.id] == change.expected else {
                throw RuleWorkspaceUndoError.ruleChanged(change.id)
            }
            if let target = change.target {
                current[change.id] = try Self.restoredRule(
                    target: target,
                    current: change.expected,
                    now: now
                )
            } else {
                current.removeValue(forKey: change.id)
            }
        }

        var result = targetOrder.compactMap { current.removeValue(forKey: $0) }
        for rule in currentRules {
            if let remaining = current.removeValue(forKey: rule.id) {
                result.append(remaining)
            }
        }
        return result
    }

    private static func index(_ rules: [Rule]) throws -> [UUID: Rule] {
        var result: [UUID: Rule] = [:]
        result.reserveCapacity(rules.count)
        for rule in rules {
            guard result.updateValue(rule, forKey: rule.id) == nil else {
                throw RuleWorkspaceUndoError.duplicateRuleID(rule.id)
            }
        }
        return result
    }

    private static func validateInteractive(_ rule: Rule?, id: UUID) throws {
        guard let rule else { return }
        guard !rule.flags.contains(.protected) else {
            throw RuleWorkspaceUndoError.protectedRule(id)
        }
        guard !rule.flags.contains(.sourceManaged) else {
            throw RuleWorkspaceUndoError.sourceManagedRule(id)
        }
    }

    private static func restoredRule(
        target: Rule,
        current: Rule?,
        now: Date
    ) throws -> Rule {
        let baseRevision = current?.revision ?? target.revision
        let (revision, overflow) = baseRevision.addingReportingOverflow(1)
        guard !overflow else { throw RuleWorkspaceUndoError.revisionOverflow(target.id) }
        return try Rule(
            id: target.id,
            lineageID: target.lineageID,
            revision: revision,
            action: target.action,
            priority: target.priority,
            process: target.process,
            destination: target.destination,
            transportProtocol: target.transportProtocol,
            port: target.port,
            direction: target.direction,
            owner: target.owner,
            profileID: target.profileID,
            localGroupID: target.localGroupID,
            expiresAt: target.expiresAt,
            isEnabled: target.isEnabled,
            flags: target.flags,
            reviewState: target.reviewState,
            source: target.source,
            notes: target.notes,
            createdAt: target.createdAt,
            modifiedAt: now
        )
    }
}

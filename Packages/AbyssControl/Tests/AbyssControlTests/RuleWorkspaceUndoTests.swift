import AbyssControl
import AbyssCore
import Foundation
import Testing

@Test func ruleWorkspaceUndoRestoresFieldsWithMonotonicRevision() throws {
    let before = try undoRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000701")!,
        revision: 4,
        enabled: false,
        note: "Before"
    )
    let changedAt = Date(timeIntervalSince1970: 2_000)
    let after = try RuleMutation.enabled(before, value: true, now: changedAt)
    let plan = try RuleWorkspaceUndoPlan(
        beforeMutation: [before],
        afterMutation: [after],
        expectedGeneration: 8
    )
    let restoredAt = Date(timeIntervalSince1970: 3_000)

    let restored = try plan.restoring(
        currentRules: [after], currentGeneration: 8, now: restoredAt
    )

    #expect(plan.affectedRuleIDs == [before.id])
    #expect(restored.count == 1)
    #expect(restored[0].id == before.id)
    #expect(restored[0].revision == 6)
    #expect(restored[0].isEnabled == false)
    #expect(restored[0].notes == "Before")
    #expect(restored[0].createdAt == before.createdAt)
    #expect(restored[0].modifiedAt == restoredAt)
}

@Test func ruleWorkspaceUndoReversesDeleteAndCreateInOriginalOrder() throws {
    let first = try undoRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000711")!,
        revision: 1,
        note: "First"
    )
    let deleted = try undoRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000712")!,
        revision: 7,
        note: "Deleted"
    )
    let created = try undoRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000713")!,
        revision: 1,
        note: "Created"
    )
    let plan = try RuleWorkspaceUndoPlan(
        beforeMutation: [first, deleted],
        afterMutation: [first, created],
        expectedGeneration: 12
    )

    let restored = try plan.restoring(
        currentRules: [first, created],
        currentGeneration: 12,
        now: Date(timeIntervalSince1970: 4_000)
    )

    #expect(restored.map(\.id) == [first.id, deleted.id])
    #expect(restored[0] == first)
    #expect(restored[1].revision == 8)
    #expect(restored[1].notes == "Deleted")
    #expect(plan.affectedRuleIDs == [deleted.id, created.id])
}

@Test func ruleWorkspaceUndoRejectsGenerationAndRuleDrift() throws {
    let before = try undoRule(id: UUID(), revision: 1, enabled: false)
    let after = try RuleMutation.enabled(
        before, value: true, now: Date(timeIntervalSince1970: 2_000)
    )
    let drifted = try RuleMutation.reviewed(
        after, value: false, now: Date(timeIntervalSince1970: 2_100)
    )
    let plan = try RuleWorkspaceUndoPlan(
        beforeMutation: [before], afterMutation: [after], expectedGeneration: 4
    )

    #expect(throws: RuleWorkspaceUndoError.generationConflict) {
        try plan.restoring(currentRules: [after], currentGeneration: 5, now: Date())
    }
    #expect(throws: RuleWorkspaceUndoError.ruleChanged(before.id)) {
        try plan.restoring(currentRules: [drifted], currentGeneration: 4, now: Date())
    }
}

@Test func ruleWorkspaceUndoRejectsNoOpAndManagedChanges() throws {
    let rule = try undoRule(id: UUID(), revision: 1)
    #expect(throws: RuleWorkspaceUndoError.noChanges) {
        try RuleWorkspaceUndoPlan(
            beforeMutation: [rule], afterMutation: [rule], expectedGeneration: 2
        )
    }

    let protected = try undoRule(id: UUID(), revision: 1, flags: [.protected])
    let changed = try Rule(
        id: protected.id,
        lineageID: protected.lineageID,
        revision: 2,
        action: protected.action,
        priority: protected.priority,
        process: protected.process,
        destination: protected.destination,
        transportProtocol: protected.transportProtocol,
        port: protected.port,
        direction: protected.direction,
        owner: protected.owner,
        isEnabled: false,
        flags: protected.flags,
        createdAt: protected.createdAt,
        modifiedAt: Date(timeIntervalSince1970: 2_000)
    )
    #expect(throws: RuleWorkspaceUndoError.protectedRule(protected.id)) {
        try RuleWorkspaceUndoPlan(
            beforeMutation: [protected], afterMutation: [changed], expectedGeneration: 2
        )
    }
}

private func undoRule(
    id: UUID,
    revision: UInt64,
    enabled: Bool = true,
    note: String = "",
    flags: RuleFlags = []
) throws -> Rule {
    try Rule(
        id: id,
        lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000700")!,
        revision: revision,
        action: .filter(.allow),
        priority: .normal,
        process: .anyProcess,
        destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol,
        port: nil,
        direction: .bidirectional,
        owner: .authorizedUser,
        isEnabled: enabled,
        flags: flags,
        notes: note,
        createdAt: Date(timeIntervalSince1970: 1_000),
        modifiedAt: Date(timeIntervalSince1970: 1_000)
    )
}

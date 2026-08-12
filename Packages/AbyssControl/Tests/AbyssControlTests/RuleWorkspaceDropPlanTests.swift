import AbyssControl
import AbyssCore
import Foundation
import Testing

@Test func ruleDropMovePreservesOtherScopeAndSkipsManagedContent() throws {
    let groupA = UUID(uuidString: "00000000-0000-0000-0000-000000000a01")!
    let groupB = UUID(uuidString: "00000000-0000-0000-0000-000000000a02")!
    let profile = UUID(uuidString: "00000000-0000-0000-0000-000000000a03")!
    let movable = try dropRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000a11")!,
        profileID: profile,
        groupID: groupA
    )
    let alreadyAssigned = try dropRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000a12")!,
        profileID: profile,
        groupID: groupB
    )
    let protected = try dropRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000a13")!,
        groupID: groupA,
        flags: [.protected]
    )
    let managed = try managedDropRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000a14")!,
        groupID: groupA
    )
    let rules = [movable, alreadyAssigned, protected, managed]
    let plan = try RuleWorkspaceDropPlan(
        rules: rules,
        selectedRuleIDs: Set(rules.map(\.id)),
        target: .localGroup(groupB),
        operation: .move
    )
    let changedAt = Date(timeIntervalSince1970: 3_000)

    let moved = try plan.applying(to: rules, newRuleIDs: [], now: changedAt)

    #expect(plan.affectedRuleIDs == [movable.id])
    #expect(plan.unchangedRuleIDs == [alreadyAssigned.id])
    #expect(plan.skippedRuleIDs == [protected.id, managed.id])
    #expect(moved.map(\.id) == rules.map(\.id))
    #expect(moved[0].profileID == profile)
    #expect(moved[0].localGroupID == groupB)
    #expect(moved[0].revision == movable.revision + 1)
    #expect(moved[0].modifiedAt == changedAt)
    #expect(moved[1] == alreadyAssigned)
    #expect(moved[2] == protected)
    #expect(moved[3] == managed)
}

@Test func optionCopyAppendsDeterministicDuplicatesWithTargetProfile() throws {
    let sourceProfile = UUID(uuidString: "00000000-0000-0000-0000-000000000b01")!
    let targetProfile = UUID(uuidString: "00000000-0000-0000-0000-000000000b02")!
    let group = UUID(uuidString: "00000000-0000-0000-0000-000000000b03")!
    let first = try dropRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000b11")!,
        profileID: sourceProfile,
        groupID: group
    )
    let second = try dropRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000b12")!,
        groupID: group
    )
    let protected = try dropRule(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000b13")!,
        flags: [.protected]
    )
    let rules = [first, protected, second]
    let copiedIDs = [
        UUID(uuidString: "00000000-0000-0000-0000-000000000b21")!,
        UUID(uuidString: "00000000-0000-0000-0000-000000000b22")!,
    ]
    let plan = try RuleWorkspaceDropPlan(
        rules: rules,
        selectedRuleIDs: Set(rules.map(\.id)),
        target: .profile(targetProfile),
        operation: .copy
    )
    let copiedAt = Date(timeIntervalSince1970: 4_000)

    let copied = try plan.applying(to: rules, newRuleIDs: copiedIDs, now: copiedAt)

    #expect(copied.prefix(rules.count).elementsEqual(rules))
    #expect(copied.suffix(2).map(\.id) == copiedIDs)
    #expect(copied.suffix(2).allSatisfy { $0.profileID == targetProfile })
    #expect(copied.suffix(2).allSatisfy { $0.localGroupID == group })
    #expect(copied.suffix(2).allSatisfy { $0.revision == 1 })
    #expect(copied.suffix(2).allSatisfy { $0.source == .manual })
    #expect(copied.suffix(2).allSatisfy { $0.createdAt == copiedAt })
    #expect(plan.skippedRuleIDs == [protected.id])
}

@Test func ruleDropRejectsMissingProtectedAndNoChangeSelections() throws {
    let group = UUID(uuidString: "00000000-0000-0000-0000-000000000c01")!
    let editable = try dropRule(id: UUID(), groupID: group)
    let protected = try dropRule(id: UUID(), flags: [.protected])
    let missing = UUID()

    #expect(throws: RuleWorkspaceDropError.emptySelection) {
        try RuleWorkspaceDropPlan(
            rules: [editable], selectedRuleIDs: [],
            target: .localGroup(group), operation: .move
        )
    }
    #expect(throws: RuleWorkspaceDropError.missingRuleIDs([missing])) {
        try RuleWorkspaceDropPlan(
            rules: [editable], selectedRuleIDs: [missing],
            target: .localGroup(group), operation: .move
        )
    }
    #expect(throws: RuleWorkspaceDropError.noEligibleRules) {
        try RuleWorkspaceDropPlan(
            rules: [protected], selectedRuleIDs: [protected.id],
            target: .localGroup(group), operation: .move
        )
    }
    #expect(throws: RuleWorkspaceDropError.noChanges) {
        try RuleWorkspaceDropPlan(
            rules: [editable], selectedRuleIDs: [editable.id],
            target: .localGroup(group), operation: .move
        )
    }
}

@Test func ruleDropRejectsStalePlansAndInvalidCopyIdentifiers() throws {
    let firstGroup = UUID()
    let secondGroup = UUID()
    let rule = try dropRule(id: UUID(), groupID: firstGroup)
    let move = try RuleWorkspaceDropPlan(
        rules: [rule], selectedRuleIDs: [rule.id],
        target: .localGroup(secondGroup), operation: .move
    )
    #expect(throws: RuleWorkspaceDropError.unexpectedNewRuleIDs) {
        try move.applying(to: [rule], newRuleIDs: [UUID()], now: Date())
    }

    let drifted = try RuleMutation.assigned(
        rule, profileID: nil, localGroupID: secondGroup, now: Date()
    )
    #expect(throws: RuleWorkspaceDropError.stalePlan) {
        try move.applying(to: [drifted], newRuleIDs: [], now: Date())
    }

    let copy = try RuleWorkspaceDropPlan(
        rules: [rule], selectedRuleIDs: [rule.id],
        target: .localGroup(secondGroup), operation: .copy
    )
    #expect(throws: RuleWorkspaceDropError.invalidNewRuleIDs) {
        try copy.applying(to: [rule], newRuleIDs: [], now: Date())
    }
    #expect(throws: RuleWorkspaceDropError.invalidNewRuleIDs) {
        try copy.applying(to: [rule], newRuleIDs: [rule.id], now: Date())
    }
}

private func dropRule(
    id: UUID,
    profileID: UUID? = nil,
    groupID: UUID? = nil,
    flags: RuleFlags = []
) throws -> Rule {
    try Rule(
        id: id,
        lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000a00")!,
        revision: 4,
        action: .filter(.allow),
        priority: .normal,
        process: .anyProcess,
        destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol,
        port: nil,
        direction: .bidirectional,
        owner: .authorizedUser,
        profileID: profileID,
        localGroupID: groupID,
        flags: flags,
        createdAt: Date(timeIntervalSince1970: 1_000),
        modifiedAt: Date(timeIntervalSince1970: 2_000)
    )
}

private func managedDropRule(id: UUID, groupID: UUID) throws -> Rule {
    try Rule(
        id: id,
        lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000a00")!,
        revision: 2,
        action: .filter(.deny),
        priority: .blocklistDeny,
        process: .anyProcess,
        destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol,
        port: nil,
        direction: .bidirectional,
        owner: .authorizedUser,
        localGroupID: groupID,
        flags: [.sourceManaged],
        source: .blocklist(sourceID: UUID()),
        createdAt: Date(timeIntervalSince1970: 1_000),
        modifiedAt: Date(timeIntervalSince1970: 2_000)
    )
}

import Foundation
import RiftControl
import RiftCore
import Testing

private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func hostRule(
    _ host: String,
    action: FilterAction = .deny,
    lineage: UUID = UUID(),
    groupID: UUID? = nil,
    profileID: UUID? = nil,
    expiresAt: Date? = nil
) throws -> Rule {
    try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(action), priority: .normal,
        process: .anyProcess,
        destination: .normalizedExactHostnameSet([DomainName(host)]),
        transportProtocol: .anySupportedProtocol, port: nil, direction: .outgoing,
        owner: .authorizedUser, profileID: profileID, localGroupID: groupID,
        expiresAt: expiresAt, createdAt: now, modifiedAt: now
    )
}

private func group(_ name: String, enabled: Bool = true) -> LocalRuleGroup {
    LocalRuleGroup(id: UUID(), name: name, note: "", isEnabled: enabled, createdAt: now, modifiedAt: now)
}

private func draft(
    lineage: UUID,
    rules: [Rule],
    groups: [LocalRuleGroup] = [],
    profiles: [PolicyProfile] = [],
    blocklists: [BlocklistSource] = []
) -> PolicyConfigurationDraft {
    PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: .alert,
        activeProfileID: nil, enabledLocalGroupIDs: Set(groups.filter(\.isEnabled).map(\.id)),
        rules: rules, localGroups: groups, profiles: profiles, blocklists: blocklists
    )
}

@Test func exportedRuleSetHoldsOnlyTheSelectedRulesAndTheirGroups() throws {
    let lineage = UUID()
    let work = group("Work")
    let other = group("Other")
    let chosen = try hostRule("tracker.example", lineage: lineage, groupID: work.id)
    let left = try hostRule("other.example", lineage: lineage, groupID: other.id)
    let blocklist = try BlocklistImportBuilder.build(
        entries: [.domain(try DomainName("ads.example"))], name: "Ads",
        contentHash: Data(repeating: 1, count: 32), lineageID: lineage, now: now
    )
    let source = draft(
        lineage: lineage, rules: [chosen, left] + blocklist.rules, groups: [work, other],
        blocklists: [blocklist.source]
    )
    let ids = Set([chosen.id] + blocklist.rules.map(\.id))
    let data = try ConfigurationArchiveCodec.exportRules(ids, from: source, appVersion: "1", now: now)
    let payload = try ConfigurationArchiveCodec.decodeRules(data)
    #expect(payload.rules == [chosen])
    #expect(payload.localGroups == [work])
    #expect(payload.blocklists.isEmpty)
    // A rule set must never replace a whole configuration.
    #expect(throws: ConfigurationArchiveError.ruleSubset) {
        try ConfigurationArchiveCodec.decode(data)
    }
}

@Test func importAddsNewRulesAndSkipsOnesYouAlreadyHave() throws {
    let lineage = UUID()
    let existing = try hostRule("tracker.example", lineage: lineage)
    let target = draft(lineage: lineage, rules: [existing])
    let incoming = try [
        hostRule("tracker.example"),
        hostRule("new.example", action: .allow),
        hostRule("expired.example", expiresAt: now.addingTimeInterval(-60)),
    ]
    let payload = ConfigurationArchivePayload(
        baseOperationMode: .alert, activeProfileID: nil, rules: incoming,
        localGroups: [], profiles: [], blocklists: []
    )
    let plan = try RuleImportPlan.make(payload, into: target, now: now)
    #expect(plan.rules.count == 1)
    #expect(plan.duplicates == 1)
    #expect(plan.skipped == 1)
    let added = try #require(plan.rules.first)
    #expect(added.id != incoming[1].id)
    #expect(added.lineageID == lineage)
    #expect(added.reviewState == .unreviewed)
    #expect(added.source == .imported)
    let applied = plan.applied(to: target)
    #expect(applied.rules == [existing, added])
    #expect(plan.summary.contains("Adds 1 rule."))
}

@Test func importPutsRulesInGroupsAndProfilesWithTheSameName() throws {
    let lineage = UUID()
    let mine = group("work")
    let target = draft(lineage: lineage, rules: [], groups: [mine])
    let theirs = group("Work")
    let newGroup = group("Games", enabled: false)
    let profile = PolicyProfile(
        id: UUID(), name: "Travel", symbolName: nil, operationModeOverride: nil,
        createdAt: now, modifiedAt: now
    )
    let payload = ConfigurationArchivePayload(
        baseOperationMode: .alert, activeProfileID: nil,
        rules: try [
            hostRule("a.example", groupID: theirs.id),
            hostRule("b.example", groupID: newGroup.id),
            hostRule("c.example", profileID: profile.id),
        ],
        localGroups: [theirs, newGroup], profiles: [profile], blocklists: []
    )
    let plan = try RuleImportPlan.make(payload, into: target, now: now)
    #expect(plan.rules[0].localGroupID == mine.id)
    #expect(plan.newGroups.map(\.name) == ["Games"])
    #expect(plan.rules[1].localGroupID == plan.newGroups.first?.id)
    #expect(plan.newProfiles.map(\.name) == ["Travel"])
    let applied = plan.applied(to: target)
    // A new group keeps its on or off state; a new profile isn't switched on.
    #expect(!applied.enabledLocalGroupIDs.contains(try #require(plan.newGroups.first).id))
    #expect(applied.activeProfileID == nil)
    try PolicyConfigurationValidator.validate(applied)
}

@Test func bulkEditChangesOnlyWhatWasPickedOnTheChosenRules() throws {
    let first = try hostRule("a.example")
    let second = try hostRule("b.example", action: .allow)
    let untouched = try hostRule("c.example")
    let edit = RuleBulkEdit(action: .filter(.allow), port: .range(try PortRange(443, 443)))
    let edited = try edit.applied(to: [first, second, untouched], ids: [first.id, second.id], now: now)
    #expect(edited[0].action == .filter(.allow))
    #expect(edited[0].port == (try PortRange(443, 443)))
    #expect(edited[0].transportProtocol == first.transportProtocol)
    #expect(edited[0].notes == first.notes)
    #expect(edited[0].revision == first.revision + 1)
    #expect(edited[1].action == .filter(.allow))
    #expect(edited[2] == untouched)
    #expect(RuleBulkEdit().isEmpty)
    let cleared = try RuleBulkEdit(port: .any, note: "").applied(to: edited[0], now: now)
    #expect(cleared.port == nil)
    #expect(cleared.notes.isEmpty)
}

@Test func importedBlocklistExceptionsArriveTurnedOff() throws {
    let lineage = UUID()
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "example.client")
    )
    let exception = try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(.allow), priority: .elevatedUser,
        process: .exact(identity),
        destination: .normalizedExactHostnameSet([DomainName("ads.example")]),
        transportProtocol: .tcp, port: try PortRange(443, 443), direction: .outgoing,
        owner: .authorizedUser, profileID: nil, localGroupID: nil, createdAt: now, modifiedAt: now
    )
    let payload = ConfigurationArchivePayload(
        baseOperationMode: .alert, activeProfileID: nil,
        rules: [exception, try hostRule("plain.example", action: .allow)],
        localGroups: [], profiles: [], blocklists: []
    )
    let plan = try RuleImportPlan.make(payload, into: draft(lineage: lineage, rules: []), now: now)
    #expect(plan.turnedOff == 1)
    #expect(plan.rules.first { $0.priority == .elevatedUser }?.isEnabled == false)
    #expect(plan.rules.first { $0.priority == .normal }?.isEnabled == true)
    #expect(plan.summary.contains("2 of them allow connections."))
    #expect(plan.summary.contains("added turned off"))
}

@Test func importedHighPriorityRulesArriveTurnedOff() throws {
    let lineage = UUID()
    // Someone else's high-priority rule would outrank this person's own
    // rules the moment it's imported, so it waits for a look.
    let high = try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(.allow), priority: .high,
        process: .anyProcess, destination: .anyEndpoint, transportProtocol: .anySupportedProtocol,
        port: nil, direction: .outgoing, owner: .authorizedUser, createdAt: now, modifiedAt: now
    )
    let payload = ConfigurationArchivePayload(
        baseOperationMode: .alert, activeProfileID: nil,
        rules: [high, try hostRule("plain.example", action: .deny)],
        localGroups: [], profiles: [], blocklists: []
    )
    let plan = try RuleImportPlan.make(payload, into: draft(lineage: lineage, rules: []), now: now)
    #expect(plan.turnedOff == 1)
    #expect(plan.rules.first { $0.priority == .high }?.isEnabled == false)
    #expect(plan.rules.first { $0.priority == .normal }?.isEnabled == true)
    #expect(plan.summary.contains("1 high-priority, blocklist-exception or system-process rule is added turned off."))

    // The rule survives an export and a restore with its tier.
    let exported = try ConfigurationArchiveCodec.export(
        draft: draft(lineage: lineage, rules: plan.rules), appVersion: "1.0", now: now
    )
    #expect(try ConfigurationArchiveCodec.decode(exported).rules.contains { $0.priority == .high })
}

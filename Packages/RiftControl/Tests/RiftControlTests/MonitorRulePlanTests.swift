import Foundation
import RiftControl
import RiftCore
import RiftIPC
import Testing

private let lineage = UUID(uuidString: "A4F31042-EA13-4D42-B307-AB1D70160322")!
private let now = Date(timeIntervalSince1970: 1_000)

private func connection() throws -> MonitorEventRow {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "example.client")
    )
    let host = try DomainName("api.example.test")
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: now, sourceAppIdentity: identity,
        sourceProcessIdentity: identity, owner: .user(uid: 501), direction: .outgoing,
        transportProtocol: .tcp, localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("203.0.113.10"), port: 443, hostname: host,
            hostnameCoverage: .observed, classes: [], interfaceSnapshotGeneration: 0
        ),
        observedHostname: host,
        metadataConfidence: [.appIdentity, .endpoint, .observedHostname, .owner]
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: now, flow: flow,
            action: .allow, reason: .unmatchedModeFallback, policy: nil
        ),
        coverage: .complete
    )
}

private func rule(
    _ action: FilterAction,
    target: MonitorRuleTarget,
    id: UUID = UUID(),
    flags: RuleFlags = [],
    destination: DestinationCondition? = nil,
    port: PortRange?? = nil
) throws -> Rule {
    try Rule(
        id: id, lineageID: lineage, revision: 1, action: .filter(action), priority: .normal,
        process: target.process, destination: destination ?? target.destination,
        transportProtocol: target.transport, port: port ?? target.port,
        direction: target.direction, owner: target.owner, flags: flags,
        createdAt: now, modifiedAt: now
    )
}

private func configuration(
    _ rules: [Rule],
    mode: OperationMode = .silentAllow
) -> PolicyConfigurationDraft {
    PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: mode,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: rules
    )
}

private func plan(
    _ action: FilterAction,
    row: MonitorEventRow,
    target: MonitorRuleTarget,
    rules: [Rule],
    mode: OperationMode = .silentAllow
) throws -> MonitorRulePlanResult {
    try MonitorRulePlan.plan(
        action: action, priority: .normal, target: target, flow: row.event.flow,
        configuration: configuration(rules, mode: mode), now: now
    ) { try rule(action, target: target) }
}

private func target(_ row: MonitorEventRow) throws -> MonitorRuleTarget {
    MonitorRuleTarget(seed: try #require(MonitorExactRuleSeed.make(from: row)))
}

@Test func anExistingBlockIsFlippedSoAllowActuallyWorks() throws {
    let row = try connection()
    let conditions = try target(row)
    let existing = try rule(.deny, target: conditions)
    let result = try plan(.allow, row: row, target: conditions, rules: [existing])
    guard case .changed(let rules, let affected) = result else {
        Issue.record("Expected a change, got \(result)")
        return
    }
    #expect(rules.count == 1)
    #expect(rules.first?.action == .filter(.allow))
    #expect(rules.first?.id == existing.id)
    #expect(affected == [existing.id])
}

@Test func stackedDuplicatesAllFlip() throws {
    let row = try connection()
    let conditions = try target(row)
    let rules = [try rule(.deny, target: conditions), try rule(.deny, target: conditions)]
    let result = try plan(.allow, row: row, target: conditions, rules: rules)
    guard case .changed(let updated, _) = result else {
        Issue.record("Expected a change, got \(result)")
        return
    }
    #expect(updated.count == 2)
    #expect(updated.allSatisfy { $0.action == .filter(.allow) })
}

@Test func aNewRuleIsAddedWhenNothingMatches() throws {
    let row = try connection()
    let result = try plan(.deny, row: row, target: try target(row), rules: [])
    guard case .changed(let rules, let affected) = result else {
        Issue.record("Expected a change, got \(result)")
        return
    }
    #expect(rules.count == 1)
    #expect(affected == [try #require(rules.first?.id)])
}

@Test func aBroaderRuleIsLeftAlone() throws {
    let row = try connection()
    let conditions = try target(row)
    let broader = try rule(.allow, target: conditions, destination: .anyEndpoint, port: .some(nil))
    let result = try plan(.deny, row: row, target: conditions, rules: [broader])
    guard case .changed(let rules, _) = result else {
        Issue.record("Expected a change, got \(result)")
        return
    }
    #expect(rules.count == 2)
    #expect(rules.first == broader)
}

@Test func nothingIsSavedWhenTheResultAlreadyHolds() throws {
    let row = try connection()
    let conditions = try target(row)
    let existing = try rule(.deny, target: conditions)
    let result = try plan(.deny, row: row, target: conditions, rules: [existing])
    #expect(result == .alreadyDecided(ruleID: existing.id))
}

@Test func aProtectedRuleIsNeverEdited() throws {
    let row = try connection()
    let conditions = try target(row)
    let protected = try rule(.deny, target: conditions, flags: [.protected])
    let result = try plan(.allow, row: row, target: conditions, rules: [protected])
    if case .changed(let rules, _) = result {
        #expect(rules.contains(protected))
    }
}

@Test func aNarrowerBlockThatWouldStillWinIsReported() throws {
    let row = try connection()
    let conditions = try target(row)
    let broadTarget = MonitorRuleTarget(
        process: conditions.process, destination: conditions.destination,
        transport: .anySupportedProtocol, port: nil,
        direction: conditions.direction, owner: conditions.owner
    )
    let narrow = try rule(.deny, target: conditions)
    let result = try plan(.allow, row: row, target: broadTarget, rules: [narrow])
    #expect(result == .overridden(by: narrow.id))
}

@Test func pausedRulesAreJudgedAsIfTheyWereOn() throws {
    let row = try connection()
    let conditions = try target(row)
    let result = try plan(.deny, row: row, target: conditions, rules: [], mode: .filterOff)
    guard case .changed = result else {
        Issue.record("Expected a change, got \(result)")
        return
    }
}

@Test func plainSentencesSayWhatChanged() {
    #expect(RulePlainLanguage.change(
        action: .deny, application: "Safari", destination: "example.test", port: 443
    ) == "Safari is now blocked from example.test on port 443.")
    #expect(RulePlainLanguage.change(
        action: .allow, application: "Safari", destination: "example.test", port: nil
    ) == "Safari can now connect to example.test.")
    #expect(RulePlainLanguage.change(
        action: .deny, application: "Music", destination: "", port: 443, incoming: true
    ) == "Incoming connections to Music on port 443 are now blocked.")
}

@Test func aPreviewDoesntClaimTheChangeHappened() {
    #expect(RulePlainLanguage.change(
        action: .deny, application: "Safari", destination: "example.test", port: nil, isPreview: true
    ) == "Safari will be blocked from example.test.")
    #expect(RulePlainLanguage.change(
        action: .allow, application: "Safari", destination: "example.test", port: nil,
        forOneHour: true, isPreview: true
    ) == "Safari will be able to connect to example.test for one hour.")
}

private func temporaryPlan(
    _ action: FilterAction,
    row: MonitorEventRow,
    target: MonitorRuleTarget,
    rules: [Rule]
) throws -> MonitorRulePlanResult {
    let expiry = now.addingTimeInterval(3_600)
    return try MonitorRulePlan.plan(
        action: action, priority: .normal, target: target, flow: row.event.flow,
        configuration: configuration(rules), expiresAt: expiry, now: now
    ) {
        try Rule(
            id: UUID(), lineageID: lineage, revision: 1, action: .filter(action),
            priority: .normal, process: target.process, destination: target.destination,
            transportProtocol: target.transport, port: target.port,
            direction: target.direction, owner: target.owner, expiresAt: expiry,
            createdAt: now, modifiedAt: now
        )
    }
}

@Test func aTemporaryChoiceNeverEndsAPermanentRuleThatDoesTheOpposite() throws {
    let row = try connection()
    let conditions = try target(row)
    let permanent = try rule(.deny, target: conditions)
    let result = try temporaryPlan(.allow, row: row, target: conditions, rules: [permanent])
    #expect(result == .permanentRuleConflict(ruleID: permanent.id))
}

@Test func aTemporaryChoiceLeavesAPermanentRuleThatAlreadyAgrees() throws {
    let row = try connection()
    let conditions = try target(row)
    let permanent = try rule(.deny, target: conditions)
    let result = try temporaryPlan(.deny, row: row, target: conditions, rules: [permanent])
    #expect(result == .alreadyDecided(ruleID: permanent.id))
}

@Test func aTemporaryChoiceStillFlipsATemporaryRule() throws {
    let row = try connection()
    let conditions = try target(row)
    let temporary = try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: .normal,
        process: conditions.process, destination: conditions.destination,
        transportProtocol: conditions.transport, port: conditions.port,
        direction: conditions.direction, owner: conditions.owner,
        expiresAt: now.addingTimeInterval(600), createdAt: now, modifiedAt: now
    )
    let result = try temporaryPlan(.allow, row: row, target: conditions, rules: [temporary])
    guard case .changed(let rules, let affected) = result else {
        Issue.record("Expected a change, got \(result)")
        return
    }
    #expect(affected == [temporary.id])
    #expect(rules.first?.action == .filter(.allow))
    #expect(rules.first?.expiresAt == now.addingTimeInterval(3_600))
}

@Test func aTemporaryChoiceFlipsADisagreeingTemporaryRuleBesideAnAgreeingPermanentOne() throws {
    let row = try connection()
    let conditions = try target(row)
    let permanent = try rule(.allow, target: conditions)
    let temporary = try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: .normal,
        process: conditions.process, destination: conditions.destination,
        transportProtocol: conditions.transport, port: conditions.port,
        direction: conditions.direction, owner: conditions.owner,
        expiresAt: now.addingTimeInterval(600), createdAt: now, modifiedAt: now
    )
    let result = try temporaryPlan(.allow, row: row, target: conditions, rules: [permanent, temporary])
    guard case .changed(let rules, _) = result else {
        Issue.record("Expected a change, got \(result)")
        return
    }
    #expect(rules.first { $0.id == permanent.id } == permanent)
    #expect(rules.first { $0.id == temporary.id }?.action == .filter(.allow))
}

@Test func aTemporaryOverrideAddsARuleWhenThePermanentOneHasTooLowAPriority() throws {
    let row = try connection()
    let conditions = try target(row)
    let permanent = try rule(.allow, target: conditions)
    let expiry = now.addingTimeInterval(3_600)
    var made: Rule?
    let result = try MonitorRulePlan.plan(
        action: .allow, priority: .elevatedUser, target: conditions, flow: row.event.flow,
        configuration: configuration([permanent]), expiresAt: expiry, now: now
    ) {
        let rule = try Rule(
            id: UUID(), lineageID: lineage, revision: 1, action: .filter(.allow),
            priority: .elevatedUser, process: conditions.process,
            destination: conditions.destination, transportProtocol: conditions.transport,
            port: conditions.port, direction: conditions.direction, owner: conditions.owner,
            expiresAt: expiry, createdAt: now, modifiedAt: now
        )
        made = rule
        return rule
    }
    guard case .changed(let rules, _) = result, let made else {
        Issue.record("Expected a new rule, got \(result)")
        return
    }
    #expect(rules.contains(permanent))
    #expect(rules.contains(made))
}

@Test func aTemporaryOverrideBeatsALowerPriorityPermanentRuleThatDisagrees() throws {
    let row = try connection()
    let conditions = try target(row)
    let permanent = try rule(.deny, target: conditions)
    let expiry = now.addingTimeInterval(3_600)
    let result = try MonitorRulePlan.plan(
        action: .allow, priority: .elevatedUser, target: conditions, flow: row.event.flow,
        configuration: configuration([permanent]), expiresAt: expiry, now: now
    ) {
        try Rule(
            id: UUID(), lineageID: lineage, revision: 1, action: .filter(.allow),
            priority: .elevatedUser, process: conditions.process,
            destination: conditions.destination, transportProtocol: conditions.transport,
            port: conditions.port, direction: conditions.direction, owner: conditions.owner,
            expiresAt: expiry, createdAt: now, modifiedAt: now
        )
    }
    guard case .changed(let rules, _) = result else {
        Issue.record("Expected a new elevated rule, got \(result)")
        return
    }
    #expect(rules.contains(permanent))
    #expect(rules.contains { $0.priority == .elevatedUser && $0.expiresAt == expiry })
}

@Test func aBroaderHighPriorityRuleIsReportedInsteadOfQuietlyOutranked() throws {
    let row = try connection()
    let conditions = try target(row)
    let highBlock = try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: .high,
        process: .anyProcess, destination: .anyEndpoint, transportProtocol: .anySupportedProtocol,
        port: nil, direction: .outgoing, owner: .authorizedUser, createdAt: now, modifiedAt: now
    )
    // A one-click Allow from the Map makes a normal rule, which a
    // high-priority Block still beats, so the Map says which rule decides.
    let result = try plan(.allow, row: row, target: conditions, rules: [highBlock])
    #expect(result == .overridden(by: highBlock.id))
    // Blocking is already what happens.
    #expect(try plan(.deny, row: row, target: conditions, rules: [highBlock])
        != .overridden(by: highBlock.id))
}

@Test func flippingAHighPriorityRuleKeepsItsPriority() throws {
    let row = try connection()
    let conditions = try target(row)
    let highBlock = try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: .high,
        process: conditions.process, destination: conditions.destination,
        transportProtocol: conditions.transport, port: conditions.port,
        direction: conditions.direction, owner: conditions.owner, createdAt: now, modifiedAt: now
    )
    let result = try plan(.allow, row: row, target: conditions, rules: [highBlock])
    guard case .changed(let rules, _) = result else {
        Issue.record("Expected a change, got \(result)")
        return
    }
    #expect(rules.count == 1)
    #expect(rules[0].action == .filter(.allow))
    #expect(rules[0].priority == .high)
}

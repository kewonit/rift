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

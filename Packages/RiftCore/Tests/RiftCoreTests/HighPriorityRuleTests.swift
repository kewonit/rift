import Foundation
import Testing
@testable import RiftCore

private let listID = RuleTestSupport.uuid(7_000)

private func exactHost() throws -> DestinationCondition {
    try .normalizedExactHostnameSet([DomainName("api.example.com")])
}

private func blocklistRule(id: UInt64) throws -> Rule {
    try RuleTestSupport.rule(
        id: id, action: .filter(.deny), priority: .blocklistDeny, destination: exactHost(),
        flags: [.sourceManaged], source: .blocklist(sourceID: listID)
    )
}

/// The winner for the default test flow: the fixture app to api.example.com
/// on port 443. Both matchers must agree.
private func winner(_ rules: [Rule]) throws -> (action: FilterAction, ruleID: UUID?) {
    let flow = try RuleTestSupport.flow()
    let reference = ReferenceRuleMatcher(rules: rules).decision(
        for: flow, context: RuleTestSupport.context(), mode: .silentAllow
    ).filter
    let compiled = CompiledRuleMatcher(rules: rules).decision(
        for: flow, context: RuleTestSupport.context(), mode: .silentAllow
    ).filter
    #expect(reference.action == compiled.action)
    #expect(reference.winningRuleID == compiled.winningRuleID)
    return (compiled.action, compiled.winningRuleID)
}

@Test func anyRuleCanBeHighPriority() throws {
    for action: RuleAction in [.filter(.allow), .filter(.deny), .filter(.ask), .notification(.notify), .privacy(.hide)] {
        let broad = try RuleTestSupport.rule(id: 7_001, action: action, priority: .high)
        #expect(broad.priority == .high)
        #expect(broad.usesExtendedPolicy)
        try broad.validateStoredRepresentation()
    }
    let domain = try RuleTestSupport.rule(
        id: 7_002, action: .filter(.deny), priority: .high,
        process: .exact(RuleTestSupport.appIdentity),
        destination: try .normalizedDomainSet([DomainName("example.com")])
    )
    #expect(domain.priority == .high)
    // The older tiers are unchanged and still need nothing new.
    #expect(!(try RuleTestSupport.rule(id: 7_003, action: .filter(.deny)).usesExtendedPolicy))
    #expect(!(try blocklistRule(id: 7_004).usesExtendedPolicy))
    #expect(!(try RuleTestSupport.rule(
        id: 7_005, action: .filter(.allow), priority: .elevatedUser,
        process: .exact(RuleTestSupport.appIdentity), destination: exactHost()
    ).usesExtendedPolicy))
}

@Test func aBlocklistRuleCannotBeHighPriority() throws {
    #expect(throws: RuleValidationError.highPriorityOnBlocklistRule) {
        try RuleTestSupport.rule(
            id: 7_010, action: .filter(.deny), priority: .high, destination: exactHost(),
            flags: [.sourceManaged], source: .blocklist(sourceID: listID)
        )
    }
}

@Test func aHighPriorityRuleBeatsEveryNormalRuleHoweverSpecific() throws {
    let broadHighDeny = try RuleTestSupport.rule(id: 7_020, action: .filter(.deny), priority: .high)
    let exactNormalAllow = try RuleTestSupport.rule(
        id: 7_021, action: .filter(.allow), process: .exact(RuleTestSupport.appIdentity),
        destination: exactHost(), transport: .tcp, port: try PortRange(443, 443)
    )
    let result = try winner([exactNormalAllow, broadHighDeny])
    #expect(result.action == .deny)
    #expect(result.ruleID == broadHighDeny.id)

    // The same holds for a high-priority Allow over a specific normal Block.
    let broadHighAllow = try RuleTestSupport.rule(id: 7_022, action: .filter(.allow), priority: .high)
    let exactNormalDeny = try RuleTestSupport.rule(
        id: 7_023, action: .filter(.deny), process: .exact(RuleTestSupport.appIdentity),
        destination: exactHost()
    )
    let allowed = try winner([exactNormalDeny, broadHighAllow])
    #expect(allowed.action == .allow)
    #expect(allowed.ruleID == broadHighAllow.id)
}

@Test func aHighPriorityAllowNeverOverridesABlocklist() throws {
    let listed = try blocklistRule(id: 7_030)
    let highAllow = try RuleTestSupport.rule(
        id: 7_031, action: .filter(.allow), priority: .high,
        process: .exact(RuleTestSupport.appIdentity), destination: exactHost()
    )
    let result = try winner([highAllow, listed])
    #expect(result.action == .deny)
    #expect(result.ruleID == listed.id)

    // Only the blocklist exception does, as before.
    let exception = try RuleTestSupport.rule(
        id: 7_032, action: .filter(.allow), priority: .elevatedUser,
        process: .exact(RuleTestSupport.appIdentity), destination: exactHost()
    )
    let excepted = try winner([highAllow, listed, exception])
    #expect(excepted.action == .allow)
    #expect(excepted.ruleID == exception.id)

    // A blocklist exception also outranks a high-priority Block.
    let highDeny = try RuleTestSupport.rule(id: 7_033, action: .filter(.deny), priority: .high)
    #expect(try winner([highDeny, exception]).ruleID == exception.id)
}

@Test func amongHighPriorityRulesTheMostSpecificWinsAndBlockBeatsAllowAtATie() throws {
    let broadDeny = try RuleTestSupport.rule(id: 7_040, action: .filter(.deny), priority: .high)
    let exactAllow = try RuleTestSupport.rule(
        id: 7_041, action: .filter(.allow), priority: .high,
        process: .exact(RuleTestSupport.appIdentity), destination: exactHost()
    )
    #expect(try winner([broadDeny, exactAllow]).ruleID == exactAllow.id)

    let tiedAllow = try RuleTestSupport.rule(id: 7_042, action: .filter(.allow), priority: .high)
    let tied = try winner([tiedAllow, broadDeny])
    #expect(tied.action == .deny)
    #expect(tied.ruleID == broadDeny.id)
}

@Test func aBuildFromBeforeTheTierRefusesTheRuleInsteadOfDemotingIt() throws {
    /// The priorities as builds before protocol 1.4 declare them.
    enum PriorityBeforeHigh: String, Codable {
        case elevatedUser, blocklistDeny, normal
    }
    let encoded = try JSONEncoder().encode(RulePriority.high)
    #expect(String(decoding: encoded, as: UTF8.self) == #""high""#)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(PriorityBeforeHigh.self, from: encoded)
    }
    // The other tiers keep the names older builds read.
    for priority in [RulePriority.elevatedUser, .blocklistDeny, .normal] {
        let name = try JSONDecoder().decode(
            PriorityBeforeHigh.self, from: try JSONEncoder().encode(priority)
        )
        #expect(name.rawValue == priority.rawValue)
    }
}

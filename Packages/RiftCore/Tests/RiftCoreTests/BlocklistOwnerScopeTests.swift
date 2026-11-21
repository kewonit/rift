import Foundation
import Testing
@testable import RiftCore

private let blockedHost = "api.example.com"

private func blocklistRule() throws -> Rule {
    try RuleTestSupport.rule(
        id: 1,
        action: .filter(.deny),
        priority: .blocklistDeny,
        destination: .normalizedExactHostnameSet([try DomainName(blockedHost)]),
        flags: [.sourceManaged],
        source: .blocklist(sourceID: RuleTestSupport.uuid(700))
    )
}

private func decisions(_ rules: [Rule], owner: FlowOwner) throws -> [Decision] {
    let flow = try RuleTestSupport.flow(owner: owner)
    let context = RuleTestSupport.context()
    return [
        ReferenceRuleMatcher(rules: rules).decision(for: flow, context: context, mode: .silentAllow),
        CompiledRuleMatcher(rules: rules).decision(for: flow, context: context, mode: .silentAllow),
    ]
}

@Test(arguments: [
    FlowOwner.user(uid: 501), .system, .user(uid: 502), .unknown,
])
func blocklistsBlockEveryOwner(owner: FlowOwner) throws {
    for decision in try decisions([try blocklistRule()], owner: owner) {
        #expect(decision.filter.action == .deny)
        #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(1))
    }
}

@Test func ordinaryRulesKeepTheirOwnerScope() throws {
    let rule = try RuleTestSupport.rule(
        id: 2,
        action: .filter(.deny),
        destination: .normalizedExactHostnameSet([try DomainName(blockedHost)])
    )
    for owner in [FlowOwner.system, .user(uid: 502), .unknown] {
        for decision in try decisions([rule], owner: owner) {
            #expect(decision.filter.action == .allow)
            #expect(decision.filter.winningRuleID == nil)
        }
    }
}

@Test func elevatedAllowStillOverridesABlocklistForItsOwner() throws {
    let exception = try RuleTestSupport.rule(
        id: 3,
        action: .filter(.allow),
        priority: .elevatedUser,
        process: .exact(RuleTestSupport.appIdentity),
        destination: .normalizedExactHostnameSet([try DomainName(blockedHost)])
    )
    let rules = [try blocklistRule(), exception]
    for decision in try decisions(rules, owner: .user(uid: 501)) {
        #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(3))
    }
    for decision in try decisions(rules, owner: .system) {
        #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(1))
    }
}

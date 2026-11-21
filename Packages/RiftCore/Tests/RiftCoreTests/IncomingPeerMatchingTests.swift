import Foundation
import Testing
@testable import RiftCore

// An incoming flow to this Mac's 192.0.2.10:22 from a peer.
private func incoming(peer: String, peerClasses: Set<EndpointClass> = []) throws -> FlowDescriptor {
    try RuleTestSupport.flow(
        direction: .incoming,
        local: try RuleTestSupport.endpoint(
            address: "192.0.2.10", port: 22, hostname: nil, classes: [.localNetwork]
        ),
        remote: try RuleTestSupport.endpoint(
            address: peer, port: 50_000, hostname: nil, classes: peerClasses
        )
    )
}

private func decisions(_ rules: [Rule], _ flow: FlowDescriptor, mode: OperationMode) -> [Decision] {
    let context = RuleTestSupport.context()
    return [
        ReferenceRuleMatcher(rules: rules).decision(for: flow, context: context, mode: mode),
        CompiledRuleMatcher(rules: rules).decision(for: flow, context: context, mode: mode),
    ]
}

@Test func ipBlocklistsBlockIncomingFlowsFromListedPeers() throws {
    let blocklist = try RuleTestSupport.rule(
        id: 1,
        action: .filter(.deny),
        priority: .blocklistDeny,
        destination: .normalizedIPSet([IPInterval(exact: try IPAddress("198.51.100.9"))]),
        flags: [.sourceManaged],
        source: .blocklist(sourceID: RuleTestSupport.uuid(700))
    )
    for decision in decisions([blocklist], try incoming(peer: "198.51.100.9"), mode: .silentAllow) {
        #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(1))
        #expect(decision.filter.action == .deny)
    }
    for decision in decisions([blocklist], try incoming(peer: "198.51.100.10"), mode: .silentAllow) {
        #expect(decision.filter.winningRuleID == nil)
    }
}

@Test func localNetworkOnIncomingFlowsMeansThePeerIsLocal() throws {
    let lan = try RuleTestSupport.rule(
        id: 2,
        action: .filter(.allow),
        destination: .endpointClass(.localNetwork),
        direction: .incoming
    )
    let fromLAN = try incoming(peer: "192.0.2.50", peerClasses: [.localNetwork])
    for decision in decisions([lan], fromLAN, mode: .silentDeny) {
        #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(2))
        #expect(decision.filter.action == .allow)
    }
    let fromInternet = try incoming(peer: "203.0.113.80")
    for decision in decisions([lan], fromInternet, mode: .silentDeny) {
        #expect(decision.filter.winningRuleID == nil)
        #expect(decision.filter.action == .deny)
    }
}

@Test func incomingRulesForALocalServiceStillMatchThisMacsAddress() throws {
    let service = try RuleTestSupport.rule(
        id: 3,
        action: .filter(.allow),
        destination: .normalizedIPSet([IPInterval(exact: try IPAddress("192.0.2.10"))]),
        port: try PortRange(22, 22),
        direction: .incoming
    )
    for decision in decisions([service], try incoming(peer: "203.0.113.80"), mode: .silentDeny) {
        #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(3))
    }
}

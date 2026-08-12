import Testing
@testable import AbyssCore

@Test func spanningIPIntervalsAreIndexedOnceAndStillMatch() throws {
    let interval = try IPInterval(cidr: IPAddress("0.0.0.0"), prefixLength: 1)
    let rule = try RuleTestSupport.rule(
        id: 1,
        action: .filter(.deny),
        destination: .normalizedIPSet([interval])
    )
    let index = CompiledRuleIndex(rules: [rule])
    #expect(index.indexedIPMembershipCount == 1)

    let inside = try RuleTestSupport.flow(
        remote: RuleTestSupport.endpoint(address: "127.255.255.255", hostname: nil)
    )
    let outside = try RuleTestSupport.flow(
        remote: RuleTestSupport.endpoint(address: "128.0.0.1", hostname: nil)
    )
    #expect(index.candidates(flow: inside, context: RuleTestSupport.context()).map(\.id) == [rule.id])
    #expect(index.candidates(flow: outside, context: RuleTestSupport.context()).isEmpty)
}

@Test func IPIndexMembershipDoesNotAmplifyAcrossFirstByteBuckets() throws {
    var intervals: [IPInterval] = []
    for first in 0..<128 {
        intervals.append(try IPInterval(
            range: IPAddress("\(first).0.0.0"),
            IPAddress("\(first + 1).255.255.255")
        ))
    }
    let rule = try RuleTestSupport.rule(
        id: 2,
        action: .filter(.deny),
        destination: .normalizedIPSet(intervals)
    )
    #expect(CompiledRuleIndex(rules: [rule]).indexedIPMembershipCount == intervals.count)
}

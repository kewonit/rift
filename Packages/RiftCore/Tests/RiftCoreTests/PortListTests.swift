import Foundation
import Testing
@testable import RiftCore

private func encoded(_ value: PortRange) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}

private func decoded(_ json: String) throws -> PortRange {
    try JSONDecoder().decode(PortRange.self, from: Data(json.utf8))
}

/// A port condition as builds before protocol 1.4 declare it.
private struct PortRangeBeforeLists: Codable, Equatable {
    let lowerBound: UInt16
    let upperBound: UInt16
}

@Test func aPortListIsReadTheWayAPersonWritesIt() throws {
    let list = try PortRange.parse("20-30, 80, 443")
    #expect(list.ranges == [20...30, 80...80, 443...443])
    #expect(list.isList)
    #expect(list.text() == "20-30, 80, 443")
    #expect(list.text(rangeSeparator: "–") == "20–30, 80, 443")
    #expect(try PortRange.parse(" 443 ") == (try PortRange(443, 443)))
    #expect(try PortRange.parse("8000–8080") == (try PortRange(8000, 8080)))
    #expect(try PortRange.parse("8000 - 8080").text() == "8000-8080")
    #expect(try PortRange.parse("443").singlePort == 443)
    #expect(try PortRange.parse("443, 80").singlePort == nil)
}

@Test func unreadablePortListsAreRefusedNotGuessed() {
    for text in ["", ",", "80,", "80,,443", "a", "80-", "-80", "1-2-3", "70000", "443x", "٤٤٣", "+80", "0x50"] {
        #expect(throws: PortRangeError.self, "\(text)") { try PortRange.parse(text) }
    }
    #expect(throws: PortRangeError.zeroPort) { try PortRange.parse("0") }
    #expect(throws: PortRangeError.zeroPort) { try PortRange.parse("80, 0-5") }
    #expect(throws: PortRangeError.reversedRange) { try PortRange.parse("443-80") }
    let tooMany = (1...17).map { String($0 * 10) }.joined(separator: ",")
    #expect(throws: PortRangeError.tooManyRanges(17)) { try PortRange.parse(tooMany) }
    #expect(throws: PortRangeError.emptyList) { try PortRange(list: []) }
}

@Test func aPortListHasOneStoredForm() throws {
    let tidy = try PortRange.parse("20-30, 80, 443")
    #expect(try PortRange.parse("443, 80, 25-30, 20-26, 80") == tidy)
    // Ranges that touch are one range.
    let joined = try PortRange.parse("80, 81, 82-90")
    #expect(joined == (try PortRange(80, 90)))
    #expect(!joined.isList)
    #expect(try PortRange.parse("1-65535, 80") == (try PortRange(1, 65535)))
    #expect(try PortRange.parse("65535, 65534").ranges == [65534...65535])
    // Seventeen written ranges that join into sixteen are fine.
    let sixteen = (1...16).map { String($0 * 10) } + ["11"]
    #expect(try PortRange.parse(sixteen.joined(separator: ",")).ranges.count == 16)
}

@Test func aListMatchesExactlyItsPorts() throws {
    let list = try PortRange.parse("20-30, 80, 443")
    for port: UInt16 in [20, 25, 30, 80, 443] { #expect(list.contains(port)) }
    for port: UInt16 in [1, 19, 31, 79, 81, 442, 444, 65535] { #expect(!list.contains(port)) }
    #expect(list.covers(try PortRange.parse("22, 80")))
    #expect(list.covers(try PortRange(21, 29)))
    #expect(!list.covers(try PortRange(29, 31)))
    #expect(!list.covers(try PortRange.parse("80, 81")))
    #expect(try PortRange(1, 1000).covers(list))
    #expect(list.overlaps(try PortRange(30, 79)))
    #expect(list.overlaps(try PortRange.parse("1, 443")))
    #expect(!list.overlaps(try PortRange.parse("31-79, 81-442")))
}

@Test func fewerPortsIsMoreSpecificWhateverTheShape() throws {
    let one = try PortRange(443, 443)
    let two = try PortRange.parse("80, 443")
    let eleven = try PortRange(20, 30)
    let fourteen = try PortRange.parse("20-30, 80, 443, 8080")
    #expect(one.span == 0)
    #expect(two.span == 1)
    #expect(eleven.span == 10)
    #expect(fourteen.span == 13)
    #expect(try PortRange(1, 65535).span == 65534)
    #expect([fourteen, eleven, two, one].sorted() == [one, two, eleven, fourteen])
    // The same number of ports: the lower first port, then the rest, decides,
    // so the order never depends on anything but the ports.
    let low = try PortRange.parse("80, 443")
    let high = try PortRange.parse("80, 8080")
    #expect(low < high)
    #expect(!(high < low))
    #expect(low < (try PortRange(80, 81)))
}

@Test func aSinglePortOrRangeEncodesAsItAlwaysDid() throws {
    #expect(try encoded(PortRange(443, 443)) == #"{"lowerBound":443,"upperBound":443}"#)
    #expect(try encoded(PortRange(8000, 8080)) == #"{"lowerBound":8000,"upperBound":8080}"#)
    #expect(try decoded(#"{"lowerBound":8000,"upperBound":8080}"#) == PortRange(8000, 8080))
    let older = try JSONDecoder().decode(
        PortRangeBeforeLists.self, from: Data(try encoded(PortRange(443, 443)).utf8)
    )
    #expect(older == PortRangeBeforeLists(lowerBound: 443, upperBound: 443))
}

@Test func aListRoundTripsAndAnOlderBuildCannotMistakeItForItsFirstRange() throws {
    let list = try PortRange.parse("20-30, 80, 443")
    let json = try encoded(list)
    #expect(json == #"{"additional":[{"lowerBound":80,"upperBound":80},{"lowerBound":443,"upperBound":443}],"lowerBound":20,"upperBound":30}"#)
    #expect(try decoded(json) == list)
    // An older build reads only the first range, so what it would write back
    // differs from what it was given. That difference is how its policy
    // check catches the list instead of applying a narrower rule.
    let older = try JSONDecoder().decode(PortRangeBeforeLists.self, from: Data(json.utf8))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    #expect(String(decoding: try encoder.encode(older), as: UTF8.self) != json)
}

@Test func storedListsMustAlreadyBeInTheirOneForm() {
    for json in [
        // Out of order, overlapping, touching, reversed, zero, empty, too many.
        #"{"additional":[{"lowerBound":20,"upperBound":30}],"lowerBound":80,"upperBound":80}"#,
        #"{"additional":[{"lowerBound":25,"upperBound":40}],"lowerBound":20,"upperBound":30}"#,
        #"{"additional":[{"lowerBound":31,"upperBound":40}],"lowerBound":20,"upperBound":30}"#,
        #"{"additional":[{"lowerBound":90,"upperBound":80}],"lowerBound":20,"upperBound":30}"#,
        #"{"additional":[{"lowerBound":0,"upperBound":5}],"lowerBound":20,"upperBound":30}"#,
        #"{"additional":[],"lowerBound":20,"upperBound":30}"#,
        #"{"additional":[{"lowerBound":80,"upperBound":80}],"lowerBound":0,"upperBound":30}"#,
    ] {
        #expect(throws: DecodingError.self, "\(json)") { try decoded(json) }
    }
    let spans = (2...17).map { #"{"lowerBound":\#($0 * 10),"upperBound":\#($0 * 10)}"# }.joined(separator: ",")
    #expect(throws: DecodingError.self) {
        try decoded(#"{"additional":[\#(spans)],"lowerBound":10,"upperBound":10}"#)
    }
}

@Test func aRuleWithAPortListMatchesOnlyItsPorts() throws {
    let rule = try RuleTestSupport.rule(
        id: 1, action: .filter(.deny), port: try PortRange.parse("20-30, 80, 443")
    )
    #expect(rule.usesExtendedPolicy)
    #expect(!(try RuleTestSupport.rule(id: 2, action: .filter(.deny), port: try PortRange(80, 90))
        .usesExtendedPolicy))
    #expect(!(try RuleTestSupport.rule(id: 3, action: .filter(.deny)).usesExtendedPolicy))
    try rule.validateStoredRepresentation()

    func action(port: UInt16?) throws -> FilterAction {
        let flow = try RuleTestSupport.flow(remote: RuleTestSupport.endpoint(port: port))
        let reference = ReferenceRuleMatcher(rules: [rule]).decision(
            for: flow, context: RuleTestSupport.context(), mode: .silentAllow
        ).filter.action
        let compiled = CompiledRuleMatcher(rules: [rule]).decision(
            for: flow, context: RuleTestSupport.context(), mode: .silentAllow
        ).filter.action
        #expect(reference == compiled)
        return compiled
    }
    for port: UInt16 in [20, 30, 80, 443] { #expect(try action(port: port) == .deny) }
    for port: UInt16 in [19, 31, 81, 8080] { #expect(try action(port: port) == .allow) }
    #expect(try action(port: nil) == .allow)
}

@Test func theRuleCoveringFewerPortsWins() throws {
    let wide = try RuleTestSupport.rule(id: 1, action: .filter(.deny), port: try PortRange(1, 1024))
    let list = try RuleTestSupport.rule(
        id: 2, action: .filter(.allow), port: try PortRange.parse("80, 443")
    )
    let exact = try RuleTestSupport.rule(id: 3, action: .filter(.deny), port: try PortRange(443, 443))
    func winner(port: UInt16) throws -> UUID? {
        let flow = try RuleTestSupport.flow(remote: RuleTestSupport.endpoint(port: port))
        let reference = ReferenceRuleMatcher(rules: [wide, list, exact]).decision(
            for: flow, context: RuleTestSupport.context(), mode: .silentAllow
        ).filter.winningRuleID
        let compiled = CompiledRuleMatcher(rules: [wide, list, exact]).decision(
            for: flow, context: RuleTestSupport.context(), mode: .silentAllow
        ).filter.winningRuleID
        #expect(reference == compiled)
        return compiled
    }
    #expect(try winner(port: 443) == exact.id)
    #expect(try winner(port: 80) == list.id)
    #expect(try winner(port: 22) == wide.id)
    #expect(try winner(port: 8080) == nil)
}

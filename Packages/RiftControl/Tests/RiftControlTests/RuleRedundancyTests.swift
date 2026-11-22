import Foundation
import RiftControl
import RiftCore
import Testing

private let lineage = UUID()
private let now = Date(timeIntervalSince1970: 1_700_000_000)

private func app(_ id: String) throws -> ProcessIdentity {
    .developerID(try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: id))
}

private func rule(
    _ action: FilterAction,
    _ process: ProcessCondition,
    _ destination: DestinationCondition = .anyEndpoint,
    port: PortRange? = nil,
    profile: UUID? = nil,
    expiresAt: Date? = nil,
    created: TimeInterval = 0
) throws -> Rule {
    try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(action), priority: .normal,
        process: process, destination: destination, transportProtocol: .tcp, port: port,
        direction: .outgoing, owner: .authorizedUser, profileID: profile, expiresAt: expiresAt,
        createdAt: now.addingTimeInterval(created), modifiedAt: now
    )
}

private func host(_ name: String) throws -> DestinationCondition {
    try .normalizedExactHostnameSet([DomainName(name)])
}

@Test func aRuleInsideABroaderRuleWithTheSameActionIsRedundant() throws {
    let safari = try app("com.apple.Safari")
    let narrow = try rule(.allow, .exact(safari), host("example.com"), port: PortRange(443, 443))
    let broad = try rule(.allow, .exact(safari))
    let result = RuleRedundancy.redundantRules(in: [narrow, broad], now: now)
    #expect(result == [narrow.id: broad.id])
}

@Test func onlyTheNewerOfTwoIdenticalRulesIsRedundant() throws {
    let safari = try app("com.apple.Safari")
    let older = try rule(.deny, .exact(safari), host("ads.example"), created: 0)
    let newer = try rule(.deny, .exact(safari), host("ads.example"), created: 10)
    #expect(RuleRedundancy.redundantRules(in: [older, newer], now: now) == [newer.id: older.id])
}

@Test func aRuleThatKeepsAnotherActionAwayIsNotRedundant() throws {
    let terminal = try app("com.apple.Terminal")
    let chrome = try app("com.google.Chrome")
    // Chrome started from Terminal acts for Terminal, so a Chrome block can
    // reach connections the narrow Terminal rule allows.
    let narrow = try rule(.allow, .exact(terminal), host("example.com"))
    let broad = try rule(.allow, .exact(terminal))
    let block = try rule(.deny, .exact(chrome))
    #expect(RuleRedundancy.redundantRules(in: [narrow, broad, block], now: now).isEmpty)
}

@Test func aConflictInAnotherProfileDoesNotKeepARule() throws {
    let safari = try app("com.apple.Safari")
    let home = UUID(), work = UUID()
    let narrow = try rule(.allow, .exact(safari), host("example.com"), profile: home)
    let broad = try rule(.allow, .exact(safari))
    let block = try rule(.deny, .anyProcess, profile: work)
    #expect(RuleRedundancy.redundantRules(in: [narrow, broad, block], now: now) == [narrow.id: broad.id])
}

@Test func aShorterLivedOrNarrowerScopedRuleIsNotACover() throws {
    let safari = try app("com.apple.Safari")
    let permanent = try rule(.allow, .exact(safari), host("example.com"))
    let temporary = try rule(.allow, .exact(safari), expiresAt: now.addingTimeInterval(60))
    let inProfile = try rule(.allow, .exact(safari), profile: UUID())
    #expect(RuleRedundancy.redundantRules(in: [permanent, temporary, inProfile], now: now).isEmpty)
}

@Test func differentPortsOrProtocolsAreNotCovered() throws {
    let safari = try app("com.apple.Safari")
    let https = try rule(.allow, .exact(safari), host("example.com"), port: PortRange(443, 443))
    let http = try rule(.allow, .exact(safari), host("example.com"), port: PortRange(80, 80))
    #expect(RuleRedundancy.redundantRules(in: [https, http], now: now).isEmpty)
}

@Test func oneLineSummariesStayShortForBlocklistRules() throws {
    let safari = try app("com.apple.Safari")
    let plain = try rule(.deny, .exact(safari), host("ads.example"), port: PortRange(443, 443))
    #expect(RuleRowViewValue.oneLineSummary(plain).hasPrefix("Block "))
    #expect(RuleRowViewValue.oneLineSummary(plain).contains("ads.example • 443"))
    #expect(!RuleRowViewValue.oneLineSummary(plain).contains("\u{FFFD}"))
    let listID = UUID()
    let names = try (0..<200).map { try DomainName("host\($0).example") }
    let listed = try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: .blocklistDeny,
        process: .anyProcess, destination: .normalizedExactHostnameSet(names),
        transportProtocol: .anySupportedProtocol, port: nil, direction: .outgoing,
        owner: .authorizedUser, flags: [.sourceManaged], source: .blocklist(sourceID: listID),
        createdAt: now, modifiedAt: now
    )
    let summary = RuleRowViewValue.oneLineSummary(listed, blocklistName: "Trackers")
    #expect(summary.hasPrefix("Block • from the blocklist “"))
    #expect(summary.contains("Trackers"))
    #expect(!summary.contains("host1.example"))
}

@Test func portListsCoverAndConflictByTheirActualPorts() throws {
    let safari = try app("com.apple.Safari")
    let list = try rule(.allow, .exact(safari), port: PortRange.parse("20-30, 80, 443"))
    let inside = try rule(.allow, .exact(safari), port: PortRange.parse("22, 443"), created: 5)
    let straddling = try rule(.allow, .exact(safari), port: PortRange(30, 80), created: 5)
    // Every port of the narrower rule is in the list, so the list covers it.
    #expect(RuleRedundancy.redundantRules(in: [list, inside], now: now) == [inside.id: list.id])
    // A range reaching into the gaps between the list's ports isn't covered.
    #expect(RuleRedundancy.redundantRules(in: [list, straddling], now: now).isEmpty)
    // A rule for only the list's first range is the redundant one of the
    // two. The list covers more, so it's never the one reported.
    let first = try rule(.allow, .exact(safari), port: PortRange(20, 30), created: -5)
    #expect(RuleRedundancy.redundantRules(in: [first, list], now: now) == [first.id: list.id])
    #expect(RuleRowViewValue.oneLineSummary(list, blocklistName: nil).contains("20–30, 80, 443"))
}

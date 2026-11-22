import Foundation
import RiftCore
import Testing
@testable import RiftControl

private let safari = ProcessIdentity.applePlatform(
    try! SignedCodeIdentity(teamIdentifier: nil, signingIdentifier: "com.apple.Safari")
)
private let curl = ProcessIdentity.applePlatform(
    try! SignedCodeIdentity(teamIdentifier: nil, signingIdentifier: "com.apple.curl")
)

private let resolver: LSRulesConverter.Resolver = { process in
    switch process {
    case .path("/Applications/Safari.app/Contents/MacOS/Safari"): safari
    case .path("/usr/bin/curl"): curl
    case .codeID(let team, let identifier):
        .developerID(try! SignedCodeIdentity(teamIdentifier: team, signingIdentifier: identifier))
    default: nil
    }
}

private func convert(_ json: String, extendedRules: Bool = true) throws -> LSRulesConverter.Conversion {
    LSRulesConverter.convert(
        try LSRulesFile.decode(Data(json.utf8)), fileName: "Fallback", lineageID: UUID(),
        resolve: resolver, suffixes: PublicSuffixList("example\nuk\nco.uk\n"),
        extendedRules: extendedRules, now: Date(timeIntervalSince1970: 100)
    )
}

@Test func portListsImportWhenTheFilterCanApplyThemAndAreSkippedWhenItCant() throws {
    let file = """
    {"rules": [
      {"process": "any", "action": "deny", "ports": "20-30, 80, 443"},
      {"process": "any", "action": "deny", "ports": "8000-8080"},
      {"process": "any", "action": "deny", "ports": "80, 81"}
    ]}
    """
    let current = try convert(file)
    #expect(current.unsupported == 0)
    #expect(current.payload.rules.map { $0.port?.text() } == ["20-30, 80, 443", "8000-8080", "80-81"])
    #expect(current.payload.rules.map(\.usesExtendedPolicy) == [true, false, false])

    // An older filter would refuse the whole policy, so the list is left out
    // and counted. Nothing is narrowed to its first range.
    let older = try convert(file, extendedRules: false)
    #expect(older.unsupported == 1)
    #expect(older.payload.rules.map { $0.port?.text() } == ["8000-8080", "80-81"])
    #expect(older.payload.rules.map(\.usesExtendedPolicy) == [false, false])
}

@Test func ruleFilesAreToldApartFromBlocklistsAndRiftsOwnFiles() {
    #expect(LSRulesFile.looksLikeRulesFile(Data(#"{"name":"x","rules":[]}"#.utf8)))
    #expect(LSRulesFile.looksLikeRulesFile(Data(#" {"denied-remote-hosts":["a.example"]}"#.utf8)))
    #expect(!LSRulesFile.looksLikeRulesFile(Data("ads.example\n".utf8)))
    #expect(!LSRulesFile.looksLikeRulesFile(Data(#"{"schemaVersion":3,"rules":[]}"#.utf8)))
}

@Test func rulesBecomeUnreviewedRiftRulesInAGroupNamedForTheFile() throws {
    let result = try convert("""
    {
      "name": "Browsing",
      "description": "Shared rules",
      "rules": [
        {"process": "/Applications/Safari.app/Contents/MacOS/Safari", "action": "allow",
         "remote-hosts": ["www.example.com", "cdn.example.com"], "ports": "443", "protocol": "tcp"},
        {"process": "identifier.TEAM123/com.example.app", "action": "deny", "remote": "local-net",
         "direction": "incoming", "disabled": true, "notes": "No sharing"},
        {"process": "/Applications/Safari.app/Contents/MacOS/Safari", "via": "/usr/bin/curl",
         "remote-addresses": "203.0.113.0/24, 198.51.100.7", "protocol": "17"},
        {"process": "any", "action": "deny", "remote-domains": "tracker.example"}
      ]
    }
    """)
    #expect(result.missingApps == 0)
    #expect(result.unsupported == 0)
    let group = try #require(result.payload.localGroups.first)
    #expect(group.name == "Browsing")
    #expect(group.note == "Shared rules")
    let rules = result.payload.rules
    #expect(rules.count == 4)
    #expect(rules.allSatisfy { $0.reviewState == .unreviewed && $0.source == .imported && $0.localGroupID == group.id })

    #expect(rules[0].action == .filter(.allow))
    #expect(rules[0].process == .exact(safari))
    #expect(rules[0].destination == (try .normalizedExactHostnameSet([
        DomainName("www.example.com"), DomainName("cdn.example.com"),
    ])))
    #expect(rules[0].port == (try PortRange(443, 443)))
    #expect(rules[0].transportProtocol == .tcp)

    #expect(rules[1].destination == .endpointClass(.localNetwork))
    #expect(rules[1].direction == .incoming)
    #expect(!rules[1].isEnabled)
    #expect(rules[1].notes == "No sharing")

    // Without an action, a rule asks; "via" makes an app-via-helper rule.
    #expect(rules[2].action == .filter(.ask))
    #expect(rules[2].process == .appViaHelper(app: safari, helper: curl))
    #expect(rules[2].transportProtocol == .udp)

    #expect(rules[3].process == .anyProcess)
    #expect(rules[3].destination == (try .normalizedDomainSet([DomainName("tracker.example")])))
}

@Test func rulesRiftCantMatchTheSameWayAreSkippedNotChanged() throws {
    let result = try convert("""
    {"rules": [
      {"process": "/Applications/Missing.app/Contents/MacOS/Missing", "action": "deny"},
      {"process": "any", "action": "deny", "protocol": "icmp"},
      {"process": "any", "action": "deny", "remote": "dns-servers"},
      {"process": "any", "action": "deny", "ports": "80,,443"},
      {"process": "any", "action": "deny", "owner": "any"},
      {"process": "any", "action": "deny", "remote-hosts": "a.example", "direction": "incoming"},
      {"process": "any", "via": "/usr/bin/curl", "action": "deny"},
      {"process": "any", "action": "deny", "remote-domains": "co.uk"},
      {"process": "any", "action": "deny", "future-key": true},
      {"process": "/usr/bin/curl", "action": "deny", "priority": "high"}
    ],
    "denied-remote-hosts": ["ads.example"]}
    """)
    #expect(result.missingApps == 1)
    // A domain rule for co.uk would cover a whole registry.
    #expect(result.unsupported == 8)
    // A high-priority rule that isn't a blocklist exception keeps its place
    // above normal rules.
    #expect(result.lowered == 0)
    #expect(result.payload.rules.count == 1)
    #expect(result.payload.rules[0].priority == .high)
    #expect(result.blockedDestinations == 1)
    #expect(result.notices.contains { $0.contains("Settings › Blocklists") })
}

@Test func highPriorityRulesKeepATierOnlyWhenTheFilterHasOne() throws {
    let file = """
    {"rules": [
      {"process": "/usr/bin/curl", "action": "deny", "priority": "high"},
      {"process": "/usr/bin/curl", "action": "allow", "priority": "high", "remote-hosts": "api.example"},
      {"process": "any", "action": "allow", "priority": "high", "remote-domains": "tracker.example"},
      {"process": "any", "action": "deny", "priority": "regular"}
    ]}
    """
    let current = try convert(file)
    // An Allow for one app to exact hosts is still the blocklist exception.
    #expect(current.payload.rules.map(\.priority) == [.high, .elevatedUser, .high, .normal])
    #expect(current.lowered == 0)

    // An older filter would refuse the whole policy over the new tier, so
    // those rules come in at normal priority and the import says so.
    let older = try convert(file, extendedRules: false)
    #expect(older.payload.rules.map(\.priority) == [.normal, .elevatedUser, .normal, .normal])
    #expect(older.lowered == 2)
    #expect(older.notices.contains { $0.contains("2 high-priority rules are added at normal priority.") })
}

@Test func blockingOnlyFilesImportAsBlocklists() throws {
    let file = try LSRulesFile.decode(Data("""
    {"denied-remote-hosts": ["ads.example"],
     "denied-remote-domains": ["tracker.example"],
     "denied-remote-addresses": ["203.0.113.0/24"],
     "rules": [{"process": "any", "action": "deny", "remote-hosts": "pixel.example"},
               {"process": "any", "action": "allow", "remote-hosts": "ok.example", "disabled": true}]}
    """.utf8))
    let entries = try LSRulesConverter.blocklistEntries(file)
    #expect(Set(entries) == [
        .domain(try DomainName("ads.example")),
        .domainAndSubdomains(try DomainName("tracker.example")),
        .address(try IPInterval(cidr: IPAddress("203.0.113.0"), prefixLength: 24)),
        .domain(try DomainName("pixel.example")),
    ])

    let mixed = try LSRulesFile.decode(Data("""
    {"rules": [{"process": "/usr/bin/curl", "action": "allow"}], "denied-remote-hosts": ["ads.example"]}
    """.utf8))
    #expect(throws: LSRulesFileError.hasOtherRules(1)) { try LSRulesConverter.blocklistEntries(mixed) }
    let bad = try LSRulesFile.decode(Data(#"{"denied-remote-hosts": ["bad%name"]}"#.utf8))
    #expect(throws: LSRulesFileError.malformedEntry("bad%name")) { try LSRulesConverter.blocklistEntries(bad) }
}

@Test func blocklistIngestionReadsRuleFiles() async throws {
    let data = Data(#"{"name": "Ads", "denied-remote-domains": ["ads.example"]}"#.utf8)
    let count = try await BlocklistIngestion.ingest(data: data, name: "Ads") { preparation in
        try BlocklistImportBuilder.build(preparation: preparation, lineageID: UUID(), now: Date()).source.entryCount
    }
    #expect(count == 1)
}

@Test func valuesOfTheWrongTypeSkipARuleRatherThanWidenIt() throws {
    let result = try convert("""
    {"rules": [
      {"process": "/usr/bin/curl", "action": "allow", "remote-hosts": "api.example", "ports": 443},
      {"process": "/usr/bin/curl", "action": "allow", "remote-hosts": "api.example", "ports": [443]},
      {"process": "/usr/bin/curl", "action": "allow", "remote": null},
      {"process": "/usr/bin/curl", "action": "allow", "remote": ["local-net"]},
      {"process": 7, "action": "allow"},
      {"process": "", "action": "allow"},
      {"process": "/usr/bin/curl", "action": "deny", "disabled": "true"},
      {"process": "/usr/bin/curl", "action": "deny", "remote-hosts": ["a.example", 3]}
    ]}
    """)
    // Only the numeric port is accepted, as port 443.
    #expect(result.payload.rules.count == 1)
    #expect(result.payload.rules.first?.port == (try PortRange(443, 443)))
    #expect(result.unsupported == 7)
}

@Test func aFilesNameCantAddLinesOrReverseTextInRift() throws {
    let result = try convert("""
    {"name": "Shared\\n\\nAll rules here block.\\u202E", "description": "Line\\u2028two",
     "rules": [{"process": "any", "action": "deny", "remote-hosts": "a.example", "notes": "ok\\u202Ehidden"}]}
    """)
    let group = try #require(result.payload.localGroups.first)
    #expect(group.name == "SharedAll rules here block.")
    #expect(group.note == "Linetwo")
    #expect(result.payload.rules.first?.notes == "okhidden")
}

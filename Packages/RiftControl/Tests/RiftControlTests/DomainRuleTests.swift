import CryptoKit
import Foundation
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

/// The copy of the Public Suffix List the app bundles.
private let bundledSuffixes: PublicSuffixList = {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let url = root.appendingPathComponent("Resources/DomainData/public_suffix_list.dat")
    return PublicSuffixList((try? String(contentsOf: url, encoding: .utf8)) ?? "")
}()

private func name(_ value: String) throws -> DomainName { try DomainName(value) }

@Test func theBundledSuffixListLoadsAndFindsRegisteredDomains() throws {
    #expect(bundledSuffixes.isAvailable)
    #expect(bundledSuffixes.ruleCount > 9_000)
    #expect(bundledSuffixes.registrableDomain(of: try name("www.example.co.uk"))?.ascii == "example.co.uk")
    #expect(bundledSuffixes.registrableDomain(of: try name("a.b.example.com"))?.ascii == "example.com")
    #expect(bundledSuffixes.registrableDomain(of: try name("example.com"))?.ascii == "example.com")
    #expect(bundledSuffixes.registrableDomain(of: try name("co.uk")) == nil)
    // Names companies listed count for "this domain", so one site on a
    // shared host isn't lumped in with every other.
    #expect(bundledSuffixes.registrableDomain(of: try name("me.github.io"))?.ascii == "me.github.io")
}

@Test func onlyRegistrySuffixesAreTooBroadForADomainRule() throws {
    #expect(bundledSuffixes.coversWholeRegistry(try name("com")))
    #expect(bundledSuffixes.coversWholeRegistry(try name("co.uk")))
    #expect(!bundledSuffixes.coversWholeRegistry(try name("example.co.uk")))
    #expect(!bundledSuffixes.coversWholeRegistry(try name("github.io")))
    // International suffixes are read in their ASCII form.
    #expect(bundledSuffixes.coversWholeRegistry(try DomainName.converting("公司.cn")))
    // Without the list, Rift refuses rather than guesses.
    #expect(PublicSuffixList.unavailable.coversWholeRegistry(try name("example.com")))
    #expect(PublicSuffixList.unavailable.registrableDomain(of: try name("www.example.com")) == nil)
}

@Test func wildcardAndExceptionRulesFollowTheListsAlgorithm() throws {
    let list = PublicSuffixList("""
    // ===BEGIN ICANN DOMAINS===
    ck
    *.ck
    !www.ck
    // ===BEGIN PRIVATE DOMAINS===
    hosted.ck
    """)
    #expect(list.registrableDomain(of: try name("a.b.ck"))?.ascii == "a.b.ck")
    #expect(list.registrableDomain(of: try name("b.ck")) == nil)
    #expect(list.registrableDomain(of: try name("x.www.ck"))?.ascii == "www.ck")
    #expect(list.coversWholeRegistry(try name("b.ck")))
    #expect(!list.coversWholeRegistry(try name("www.ck")))
    #expect(list.registrableDomain(of: try name("site.hosted.ck"))?.ascii == "site.hosted.ck")
}

@Test func internationalNamesConvertToTheirASCIIForm() throws {
    #expect(try DomainName.converting("Bücher.de").ascii == "xn--bcher-kva.de")
    #expect(try DomainName.converting("example.com.").ascii == "example.com")
}

@Test func theEditorMakesSubdomainRulesButNeverForARegistry() throws {
    let both = try DestinationEditorParser.parse(
        "example.com, *.example.net", domainsIncludeChildren: true, suffixes: bundledSuffixes
    )
    #expect(both == (try .normalizedDomainSet([name("example.com"), name("example.net")])))
    // `*.` asks for subdomains even with the switch off.
    let starred = try DestinationEditorParser.parse(
        "*.example.org", domainsIncludeChildren: false, suffixes: bundledSuffixes
    )
    #expect(starred == (try .normalizedDomainSet([name("example.org")])))
    #expect(throws: DestinationEditorError.wholeRegistry("co.uk")) {
        try DestinationEditorParser.parse("co.uk", domainsIncludeChildren: true, suffixes: bundledSuffixes)
    }
    #expect(throws: DestinationEditorError.childDomainsNeedNames) {
        try DestinationEditorParser.parse("203.0.113.8", domainsIncludeChildren: true, suffixes: bundledSuffixes)
    }
    let exact = try DestinationEditorParser.parse(
        "bücher.de", domainsIncludeChildren: false, suffixes: bundledSuffixes
    )
    #expect(exact == (try .normalizedExactHostnameSet([name("xn--bcher-kva.de")])))
}

private func connection(host: String?, direction: TrafficDirection = .outgoing) throws -> MonitorEventRow {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "example.client")
    )
    let hostname = try host.map { try DomainName($0) }
    let endpoint = Endpoint(
        address: try IPAddress("203.0.113.10"), port: 443, hostname: hostname,
        hostnameCoverage: hostname == nil ? .absent : .observed, classes: [],
        interfaceSnapshotGeneration: 0
    )
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(timeIntervalSince1970: 1_000), sourceAppIdentity: identity,
        sourceProcessIdentity: identity, owner: .user(uid: 501), direction: direction,
        transportProtocol: .tcp, localEndpoint: direction == .incoming ? endpoint : nil,
        remoteEndpoint: endpoint, observedHostname: direction == .outgoing ? hostname : nil,
        metadataConfidence: [.appIdentity, .endpoint, .observedHostname, .owner]
    )
    return MonitorEventRow(
        event: RuntimeEvent(
            providerEpoch: UUID(), sequence: 1, occurredAt: Date(timeIntervalSince1970: 1_000), flow: flow,
            action: .allow, reason: .unmatchedModeFallback, policy: nil
        ),
        coverage: .complete
    )
}

@Test func theMapOffersTheRegisteredDomainWhenThereIsOne() throws {
    let row = try connection(host: "cdn.images.example.co.uk")
    let options = MonitorRuleScope.options(for: [row], suffixes: bundledSuffixes)
    #expect(options == [.thisHost, .thisDomain, .allDestinations, .exactConnection])
    let target = try #require(try MonitorRuleScope.target(.thisDomain, for: row, suffixes: bundledSuffixes))
    #expect(target.destination == (try .normalizedDomainSet([name("example.co.uk")])))
    #expect(target.port == nil)
    #expect(MonitorRuleScope.title(.thisDomain, host: "cdn.images.example.co.uk", domain: "example.co.uk", port: 443)
        == "example.co.uk and its subdomains")

    // Two hosts under one domain can share a domain rule.
    let pair = [try connection(host: "a.example.com"), try connection(host: "b.example.com")]
    #expect(MonitorRuleScope.options(for: pair, suffixes: bundledSuffixes) == [.thisDomain, .allDestinations])
    // No name, no domain; and incoming connections keep the exact rule.
    #expect(!MonitorRuleScope.options(for: [try connection(host: nil)], suffixes: bundledSuffixes).contains(.thisDomain))
    #expect(MonitorRuleScope.options(for: [try connection(host: "a.example.com", direction: .incoming)],
                                     suffixes: bundledSuffixes) == [.exactConnection])
}

@Test func alertsCanCoverTheRegisteredDomain() throws {
    let identity = ProcessIdentity.developerID(
        try SignedCodeIdentity(teamIdentifier: "TEAM123", signingIdentifier: "example.client")
    )
    func prompt(host: String?) throws -> PromptRequest {
        PromptRequest(
            nonce: UUID(), providerEpoch: UUID(), lineageID: UUID(), generation: 1,
            flowID: UUID(), observedAt: Date(), owner: .user(uid: 501),
            appIdentity: identity, processIdentity: identity, direction: .outgoing,
            transportProtocol: .tcp,
            endpoint: Endpoint(
                address: try IPAddress("203.0.113.9"), port: 443, hostname: try host.map { try DomainName($0) },
                hostnameCoverage: host == nil ? .absent : .observed, classes: [], interfaceSnapshotGeneration: 0
            ),
            winningRuleID: nil, affectingRuleIDs: []
        )
    }
    let rule = try AlertRuleBuilder.build(
        prompt: prompt(host: "api.example.com"), action: .deny, lineageID: UUID(), authorizedUID: 501,
        expiresAt: nil, destinationScope: .observedDomain, suffixes: bundledSuffixes, now: Date()
    )
    #expect(rule.destination == (try .normalizedDomainSet([name("example.com")])))
    #expect(rule.port == nil)
    #expect(throws: AlertRuleBuilderError.domainUnavailable) {
        try AlertRuleBuilder.build(
            prompt: prompt(host: nil), action: .deny, lineageID: UUID(), authorizedUID: 501,
            expiresAt: nil, destinationScope: .observedDomain, suffixes: bundledSuffixes, now: Date()
        )
    }
}

@Test func plainNamesCoverSubdomainsWhileHostsFilesStayExact() throws {
    let plain = try BlocklistParser.parse(Data("ads.example\n||track.example^\n*.wild.example\n".utf8))
    #expect(plain == [
        .domainAndSubdomains(try name("ads.example")),
        .domainAndSubdomains(try name("track.example")),
        .domainAndSubdomains(try name("wild.example")),
    ])
    let hosts = try BlocklistParser.parse(Data("0.0.0.0 ads.example tracker.example\n".utf8))
    #expect(hosts == [.domain(try name("ads.example")), .domain(try name("tracker.example"))])
}

@Test func importedSubdomainEntriesBecomeDomainRulesThatValidate() throws {
    let entries: [BlocklistEntry] = [
        .domainAndSubdomains(try name("ads.example.com")),
        .domainAndSubdomains(try name("co.uk")),
        .domain(try name("ads.example.com")),
        .domain(try name("exact.example.net")),
        .address(IPInterval(exact: try IPAddress("203.0.113.8"))),
    ]
    let lineage = UUID()
    let result = try BlocklistImportBuilder.build(
        entries: entries, name: "Fixture", contentHash: Data(SHA256.hash(data: Data("f".utf8))),
        lineageID: lineage, now: Date(timeIntervalSince1970: 1), suffixes: bundledSuffixes
    )
    let destinations = result.rules.map(\.destination)
    // co.uk would cover a whole registry, so it stays exact; the duplicate
    // exact name is already covered.
    #expect(destinations.contains(try .normalizedDomainSet([name("ads.example.com")])))
    #expect(destinations.contains(try .normalizedExactHostnameSet([name("co.uk"), name("exact.example.net")])))
    #expect(result.source.domainEntryCount == 3)
    #expect(result.source.entryCount == 4)
    let draft = PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow, baseOperationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: result.rules, localGroups: [], profiles: [],
        blocklists: [result.source]
    )
    try PolicyConfigurationValidator.validate(draft)

    // Check Entry finds the subdomain entry for a name under it, and the
    // compiled policy still drops an entry that's turned off.
    let covering = try BlocklistEntryOverrides.coveringEntries(for: "x.ads.example.com", configuration: draft)
    #expect(covering.map(\.entry) == [.domainAndSubdomains(try name("ads.example.com"))])
    let off = PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow, baseOperationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: result.rules, localGroups: [], profiles: [],
        blocklists: [result.source], disabledBlocklistEntries: [.domainAndSubdomains(try name("ads.example.com"))]
    )
    let effective = try BlocklistPolicyCompiler.effectiveRules(for: off)
    #expect(!effective.contains { if case .domainSet = $0.destination { true } else { false } })
}

@Test func subdomainEntriesSurviveStorageCoding() throws {
    let entry = BlocklistEntry.domainAndSubdomains(try name("example.com"))
    let data = try JSONEncoder().encode(entry)
    #expect(try JSONDecoder().decode(BlocklistEntry.self, from: data) == entry)
    #expect(entry.description == "*.example.com")
}

@Test func onlyApplesOwnCodeGetsAServiceNote() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    let notes = ProcessNotes(try Data(contentsOf: root.appendingPathComponent("Resources/Explanations/process-notes.json")))
    let trustd = try SignedCodeIdentity(teamIdentifier: nil, signingIdentifier: "com.apple.trustd")
    #expect(notes.note(for: .applePlatform(trustd))?.contains("certificate") == true)
    // A Developer ID app named like an Apple service gets nothing.
    let impostor = try SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "com.apple.trustd")
    #expect(notes.note(for: .developerID(impostor)) == nil)

    let search = try #require(ConnectionWebSearch.url(
        identity: .applePlatform(trustd), fallbackName: "trustd", host: "ocsp.apple.com"
    ))
    #expect(search.host == "duckduckgo.com")
    #expect(URLComponents(url: search, resolvingAgainstBaseURL: false)?.queryItems?.first?.value
        == "macOS trustd ocsp.apple.com")
}

@Test func oneStarredNameDoesntWidenTheOthers() throws {
    #expect(throws: DestinationEditorError.someSubdomains) {
        try DestinationEditorParser.parse("foo.com, *.bar.com", domainsIncludeChildren: false, suffixes: bundledSuffixes)
    }
    // With the switch on, `*.` changes nothing.
    let both = try DestinationEditorParser.parse("foo.com, *.bar.com", domainsIncludeChildren: true, suffixes: bundledSuffixes)
    #expect(both == (try .normalizedDomainSet([name("foo.com"), name("bar.com")])))
}

@Test func checkEntryFindsTheRangeThatBlocksAnAddress() throws {
    let lineage = UUID()
    let result = try BlocklistImportBuilder.build(
        entries: [.address(try IPInterval(cidr: IPAddress("203.0.113.0"), prefixLength: 24))],
        name: "Ranges", contentHash: Data(SHA256.hash(data: Data("r".utf8))),
        lineageID: lineage, now: Date(timeIntervalSince1970: 1), suffixes: bundledSuffixes
    )
    let draft = PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow, baseOperationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: result.rules, localGroups: [], profiles: [],
        blocklists: [result.source]
    )
    let covering = try BlocklistEntryOverrides.coveringEntries(for: "203.0.113.8", configuration: draft)
    #expect(covering.map(\.entry) == [.address(try IPInterval(cidr: IPAddress("203.0.113.0"), prefixLength: 24))])
    #expect(try BlocklistEntryOverrides.coveringEntries(for: "198.51.100.1", configuration: draft).isEmpty)
}

@Test func fullWidthAndOtherCompatibilityFormsFoldLikeBrowsers() throws {
    #expect(try DomainName.converting("ｅｘａｍｐｌｅ。com").ascii == "example.com")
    #expect(try DomainName.converting("𝐚pple.com").ascii == "apple.com")
    #expect(try DomainName.converting("Bücher.de.").ascii == "xn--bcher-kva.de")
}

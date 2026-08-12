import AbyssControl
import AbyssCore
import Foundation
import Testing

@Test func blocklistParserAcceptsOnlyNormalizedDenyEntries() throws {
    let input = """
    # comment
    0.0.0.0 ads.example.test tracker.example.test
    203.0.113.0/24
    2001:db8::1
    ads.example.test
    """.data(using: .utf8)!
    let entries = try BlocklistParser.parse(input)
    #expect(entries.count == 4)
    #expect(throws: BlocklistParserError.malformedLine(1)) {
        try BlocklistParser.parse(Data("@@bad".utf8))
    }
}

@Test func blocklistParserAcceptsHyphenatedDomainsWithoutTreatingThemAsRanges() throws {
    let entries = try BlocklistParser.parse(Data("ads-edge.example.test\napi-v2.example.test\n".utf8))
    #expect(entries == [
        .domain(try DomainName("ads-edge.example.test")),
        .domain(try DomainName("api-v2.example.test")),
    ])
}

@Test func blocklistParserOmitsAddressesFromGeneralHostsFileMappings() throws {
    let input = """
    192.0.2.44 ads-edge.example.test ads.example.test
    2001:db8::44 tracker.example.test
    198.51.100.20
    """.data(using: .utf8)!
    let entries = try BlocklistParser.parse(input)

    #expect(entries.contains(.domain(try DomainName("ads-edge.example.test"))))
    #expect(entries.contains(.domain(try DomainName("ads.example.test"))))
    #expect(entries.contains(.domain(try DomainName("tracker.example.test"))))
    #expect(entries.contains(.address(IPInterval(exact: try IPAddress("198.51.100.20")))))
    #expect(!entries.contains(.address(IPInterval(exact: try IPAddress("192.0.2.44")))))
    #expect(!entries.contains(.address(IPInterval(exact: try IPAddress("2001:db8::44")))))
}

@Test func blocklistParserStillAcceptsIPv4AndIPv6Ranges() throws {
    let entries = try BlocklistParser.parse(Data("""
    203.0.113.10-203.0.113.20
    2001:db8::10-2001:db8::20
    """.utf8))
    #expect(entries.contains(.address(try IPInterval(
        range: IPAddress("203.0.113.10"),
        IPAddress("203.0.113.20")
    ))))
    #expect(entries.contains(.address(try IPInterval(
        range: IPAddress("2001:db8::10"),
        IPAddress("2001:db8::20")
    ))))
}

@Test func blocklistImportBuildsBoundedManagedDenyRules() throws {
    let domains = try (0..<300).map { index in
        BlocklistEntry.domain(try DomainName("host\(index).example"))
    }
    let result = try BlocklistImportBuilder.build(
        entries: domains,
        name: " Test Source ",
        contentHash: Data(repeating: 7, count: 32),
        lineageID: UUID(),
        now: Date(timeIntervalSince1970: 10)
    )
    #expect(result.source.name == "Test Source")
    #expect(result.source.entryCount == 300)
    #expect(result.source.domainEntryCount == 300)
    #expect(result.source.addressEntryCount == 0)
    #expect(result.rules.count == 2)
    #expect(result.rules.allSatisfy { $0.action == .filter(.deny) })
    #expect(result.rules.allSatisfy { $0.priority == .blocklistDeny })
    #expect(result.rules.allSatisfy { $0.flags.contains(.sourceManaged) })
    #expect(result.rules.allSatisfy { $0.destination.memberCount <= PolicyLimits.maximumDestinationMembers })
    #expect(result.rules.allSatisfy {
        if case .exactHostnameSet = $0.destination { return true }
        return false
    })
}

@Test func blocklistImportKeepsSuffixLookingEntriesExactUntilPSLIsAdmitted() throws {
    let entries = try ["com", "co.uk", "github.io", "ads.example.com"].map {
        BlocklistEntry.domain(try DomainName($0))
    }
    let result = try BlocklistImportBuilder.build(
        entries: entries,
        name: "Exact host safety",
        contentHash: Data(repeating: 8, count: 32),
        lineageID: UUID(),
        now: Date(timeIntervalSince1970: 20)
    )
    #expect(result.rules.allSatisfy {
        if case .exactHostnameSet = $0.destination { return true }
        return false
    })

    let matcher = ReferenceRuleMatcher(rules: result.rules)
    let context = MatchContext(
        activeProfileID: nil,
        enabledLocalGroupIDs: [],
        authorizedUID: 501,
        policyTime: PolicyTime(
            now: Date(timeIntervalSince1970: 20),
            expiryMetadata: .available(alreadyExpired: [])
        )
    )
    for hostname in ["example.com", "service.co.uk", "site.github.io", "sub.ads.example.com"] {
        let decision = matcher.decision(
            for: try blocklistFlow(hostname: hostname),
            context: context,
            mode: .silentAllow
        )
        #expect(decision.filter.action == .allow)
        #expect(decision.filter.winningRuleID == nil)
    }
    let exact = matcher.decision(
        for: try blocklistFlow(hostname: "ads.example.com"),
        context: context,
        mode: .silentAllow
    )
    #expect(exact.filter.action == .deny)
    #expect(exact.filter.winningRuleID != nil)
}

@Test func blocklistImportRejectsUniversalAddressRangesButKeepsNarrowerCIDRs() throws {
    let universal: [(IPInterval, IPAddress.Family)] = [
        (try IPInterval(cidr: IPAddress("0.0.0.0"), prefixLength: 0), .ipv4),
        (try IPInterval(range: IPAddress("0.0.0.0"), IPAddress("255.255.255.255")), .ipv4),
        (try IPInterval(cidr: IPAddress("::"), prefixLength: 0), .ipv6),
        (try IPInterval(
            range: IPAddress("::"),
            IPAddress("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff")
        ), .ipv6),
    ]
    for (interval, family) in universal {
        #expect(throws: BlocklistImportError.universalAddressRange(family)) {
            try BlocklistImportBuilder.build(
                entries: [.address(interval)],
                name: "Universal range",
                contentHash: Data(repeating: 9, count: 32),
                lineageID: UUID(),
                now: Date(timeIntervalSince1970: 30)
            )
        }
    }

    let narrower = try BlocklistImportBuilder.build(
        entries: [
            .address(try IPInterval(cidr: IPAddress("0.0.0.0"), prefixLength: 1)),
            .address(try IPInterval(cidr: IPAddress("::"), prefixLength: 1)),
        ],
        name: "Narrower ranges",
        contentHash: Data(repeating: 10, count: 32),
        lineageID: UUID(),
        now: Date(timeIntervalSince1970: 31)
    )
    #expect(narrower.source.addressEntryCount == 2)
    #expect(narrower.rules.count == 1)
}

@Test func policyDefinitionNamesAreBoundedAndCollisionSafe() throws {
    #expect(try PolicyDefinitionValidator.name("  Work  ") == "Work")
    #expect(throws: PolicyDefinitionError.emptyName) {
        try PolicyDefinitionValidator.name(" \n ")
    }
    #expect(throws: PolicyDefinitionError.nameTooLong) {
        try PolicyDefinitionValidator.name(String(repeating: "a", count: 129))
    }
    #expect(throws: PolicyDefinitionError.duplicateName) {
        try PolicyDefinitionValidator.rejectCollision(
            "WÖRK", existing: [(UUID(), "work")]
        )
    }
    #expect(throws: PolicyDefinitionError.noteTooLong) {
        try PolicyDefinitionValidator.note(
            String(repeating: "n", count: PolicyLimits.maximumNotesScalars + 1)
        )
    }
}

private func blocklistFlow(hostname: String) throws -> FlowDescriptor {
    let domain = try DomainName(hostname)
    let remote = Endpoint(
        address: try IPAddress("203.0.113.9"),
        port: 443,
        hostname: domain,
        hostnameCoverage: .observed,
        classes: [],
        interfaceSnapshotGeneration: 1
    )
    return FlowDescriptor(
        flowID: UUID(),
        observedAt: Date(timeIntervalSince1970: 20),
        sourceAppIdentity: nil,
        sourceProcessIdentity: nil,
        owner: .user(uid: 501),
        direction: .outgoing,
        transportProtocol: .tcp,
        localEndpoint: nil,
        remoteEndpoint: remote,
        observedHostname: domain,
        metadataConfidence: [.endpoint, .observedHostname, .owner]
    )
}

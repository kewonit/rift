import Foundation
import Testing
@testable import AbyssCore

@Test func priorityOrderAllowsOnlyElevatedOverrideOfBlocklist() throws {
    let sourceID = RuleTestSupport.uuid(700)
    let rules = [
        try RuleTestSupport.rule(id: 1, action: .filter(.allow)),
        try RuleTestSupport.rule(
            id: 2,
            action: .filter(.deny),
            priority: .blocklistDeny,
            flags: [.sourceManaged],
            source: .blocklist(sourceID: sourceID)
        ),
        try RuleTestSupport.rule(
            id: 3,
            action: .filter(.allow),
            priority: .elevatedUser,
            process: .exact(RuleTestSupport.appIdentity),
            destination: .normalizedExactHostnameSet([try DomainName("api.example.com")])
        ),
    ]
    let decision = ReferenceRuleMatcher(rules: rules).decision(
        for: try RuleTestSupport.flow(),
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(decision.filter.action == .allow)
    #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(3))
    #expect(decision.filter.affectingRuleIDs == [
        RuleTestSupport.uuid(3), RuleTestSupport.uuid(2), RuleTestSupport.uuid(1),
    ])
}

@Test func destinationTypesFollowStrictPrecedence() throws {
    let host = try DomainName("api.example.com")
    let rules = [
        try RuleTestSupport.rule(id: 10, action: .filter(.deny), destination: .anyEndpoint),
        try RuleTestSupport.rule(
            id: 11,
            action: .filter(.deny),
            destination: .normalizedDomainSet([try DomainName("example.com")])
        ),
        try RuleTestSupport.rule(
            id: 12,
            action: .filter(.deny),
            destination: .normalizedExactHostnameSet([host])
        ),
        try RuleTestSupport.rule(
            id: 13,
            action: .filter(.allow),
            destination: .normalizedIPSet([IPInterval(exact: try IPAddress("203.0.113.7"))])
        ),
    ]
    let decision = ReferenceRuleMatcher(rules: rules).decision(
        for: try RuleTestSupport.flow(),
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(decision.filter.action == .allow)
    #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(13))
}

@Test func shorterIPAndPortRangesThenSpecificProtocolWin() throws {
    let broad = try IPInterval(cidr: IPAddress("203.0.113.0"), prefixLength: 24)
    let narrow = try IPInterval(cidr: IPAddress("203.0.113.0"), prefixLength: 28)
    let rules = [
        try RuleTestSupport.rule(
            id: 20,
            action: .filter(.deny),
            destination: .normalizedIPSet([broad]),
            port: try PortRange(1, 65_535)
        ),
        try RuleTestSupport.rule(
            id: 21,
            action: .filter(.allow),
            destination: .normalizedIPSet([narrow]),
            transport: .tcp,
            port: try PortRange(443, 443)
        ),
    ]
    let decision = ReferenceRuleMatcher(rules: rules).decision(
        for: try RuleTestSupport.flow(),
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(21))
}

@Test func pairIdentityBeatsExactAndAnyProcess() throws {
    let rules = [
        try RuleTestSupport.rule(id: 30, action: .filter(.deny)),
        try RuleTestSupport.rule(
            id: 31,
            action: .filter(.deny),
            process: .exact(RuleTestSupport.helperIdentity)
        ),
        try RuleTestSupport.rule(
            id: 32,
            action: .filter(.allow),
            process: .appViaHelper(
                app: RuleTestSupport.appIdentity,
                helper: RuleTestSupport.helperIdentity
            )
        ),
    ]
    let flow = try RuleTestSupport.flow(process: RuleTestSupport.helperIdentity)
    let decision = ReferenceRuleMatcher(rules: rules).decision(
        for: flow,
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(32))
}

@Test func filterNotificationAndPrivacyResolveIndependently() throws {
    let rules = [
        try RuleTestSupport.rule(id: 40, action: .filter(.deny)),
        try RuleTestSupport.rule(id: 41, action: .notification(.notify)),
        try RuleTestSupport.rule(id: 42, action: .privacy(.hide)),
    ]
    let decision = CompiledRuleMatcher(rules: rules).decision(
        for: try RuleTestSupport.flow(),
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(decision.filter.action == .deny)
    #expect(decision.notification.action == .notify)
    #expect(decision.privacy.action == .hidden)
}

@Test func missingValuesNeverBecomeWildcards() throws {
    let domainRule = try RuleTestSupport.rule(
        id: 50,
        action: .filter(.deny),
        destination: .normalizedDomainSet([try DomainName("example.com")])
    )
    let missingHost = try RuleTestSupport.flow(observedHostname: .some(nil))
    let hostDecision = ReferenceRuleMatcher(rules: [domainRule]).decision(
        for: missingHost,
        context: RuleTestSupport.context(),
        mode: .silentAllow
    )
    #expect(hostDecision.filter.action == .allow)
    #expect(hostDecision.issues.contains(DecisionIssue(category: .filter, reason: .hostnameUnavailable)))

    let portRule = try RuleTestSupport.rule(
        id: 51,
        action: .filter(.deny),
        port: try PortRange(443, 443)
    )
    let noPort = try RuleTestSupport.flow(remote: RuleTestSupport.endpoint(port: nil))
    let portDecision = ReferenceRuleMatcher(rules: [portRule]).decision(
        for: noPort,
        context: RuleTestSupport.context(),
        mode: .silentAllow
    )
    #expect(portDecision.filter.action == .allow)
    #expect(portDecision.issues.contains(DecisionIssue(category: .filter, reason: .portUnavailable)))

    let identityRule = try RuleTestSupport.rule(
        id: 52,
        action: .filter(.deny),
        process: .exact(RuleTestSupport.appIdentity)
    )
    let noIdentity = try RuleTestSupport.flow(app: nil, process: nil)
    let identityDecision = ReferenceRuleMatcher(rules: [identityRule]).decision(
        for: noIdentity,
        context: RuleTestSupport.context(),
        mode: .silentAllow
    )
    #expect(identityDecision.filter.action == .allow)
    #expect(identityDecision.issues.contains(DecisionIssue(category: .filter, reason: .identityUnavailable)))
}

@Test func unsupportedProtocolAlwaysAllowsAndReportsAcrossModesAndMatchers() throws {
    let rules = [
        try RuleTestSupport.rule(id: 60, action: .filter(.deny)),
        try RuleTestSupport.rule(id: 61, action: .notification(.notify)),
        try RuleTestSupport.rule(id: 62, action: .privacy(.hide)),
    ]
    let flow = try RuleTestSupport.flow(transport: .unsupported(number: 1))
    let modes: [OperationMode] = [
        .alert, .silentAllow, .silentDeny, .filterOff, .degradedFallback,
    ]

    for mode in modes {
        let decisions = [
            ReferenceRuleMatcher(rules: rules).decision(
                for: flow,
                context: RuleTestSupport.context(),
                mode: mode
            ),
            CompiledRuleMatcher(rules: rules).decision(
                for: flow,
                context: RuleTestSupport.context(),
                mode: mode
            ),
        ]
        for decision in decisions {
            #expect(decision.filter.action == .allow)
            #expect(decision.filter.winningRuleID == nil)
            #expect(decision.filter.affectingRuleIDs.isEmpty)
            #expect(decision.notification.action == .none)
            #expect(decision.privacy.action == .visible)
            #expect(decision.issues.contains(
                DecisionIssue(category: .filter, reason: .unsupportedProtocol)
            ))
            #expect(decision.issues.contains(
                DecisionIssue(category: .notification, reason: .unsupportedProtocol)
            ))
            #expect(decision.issues.contains(
                DecisionIssue(category: .privacy, reason: .unsupportedProtocol)
            ))
        }
    }
}

@Test func incomingRulesUseLocalListeningPort() throws {
    let local = try RuleTestSupport.endpoint(address: "192.0.2.5", port: 8_080, hostname: nil)
    let remote = try RuleTestSupport.endpoint(address: "198.51.100.5", port: 44_000, hostname: nil)
    let flow = try RuleTestSupport.flow(
        direction: .incoming,
        local: local,
        remote: remote,
        observedHostname: .some(nil)
    )
    let rule = try RuleTestSupport.rule(
        id: 70,
        action: .filter(.deny),
        port: try PortRange(8_080, 8_080),
        direction: .incoming
    )
    let decision = ReferenceRuleMatcher(rules: [rule]).decision(
        for: flow,
        context: RuleTestSupport.context(),
        mode: .silentAllow
    )
    #expect(decision.filter.action == .deny)
}

@Test func expiryTombstonesAndUnavailableMetadataNeverReactivateRules() throws {
    let rule = try RuleTestSupport.rule(
        id: 80,
        action: .filter(.deny),
        expiresAt: RuleTestSupport.now.addingTimeInterval(3_600)
    )
    let key = try #require(rule.expiryKey)
    for metadata in [
        ExpiryMetadata.available(alreadyExpired: [key]),
        ExpiryMetadata.unavailable,
    ] {
        let decision = ReferenceRuleMatcher(rules: [rule]).decision(
            for: try RuleTestSupport.flow(),
            context: RuleTestSupport.context(expiryMetadata: metadata),
            mode: .silentAllow
        )
        #expect(decision.filter.action == .allow)
    }
}

@Test func groupsAndProfilesFilterEligibilityWithoutChangingPrecedence() throws {
    let groupID = RuleTestSupport.uuid(900)
    let profileID = RuleTestSupport.uuid(901)
    let rule = try RuleTestSupport.rule(
        id: 90,
        action: .filter(.deny),
        profileID: profileID,
        groupID: groupID
    )
    let matcher = ReferenceRuleMatcher(rules: [rule])
    let flow = try RuleTestSupport.flow()
    #expect(matcher.decision(
        for: flow,
        context: RuleTestSupport.context(),
        mode: .silentAllow
    ).filter.action == .allow)
    #expect(matcher.decision(
        for: flow,
        context: RuleTestSupport.context(activeProfileID: profileID, enabledGroups: [groupID]),
        mode: .silentAllow
    ).filter.action == .deny)
}

@Test func reviewStateIsAnnotationOnlyAndRuleIDBreaksTrueTies() throws {
    let reviewed = try RuleTestSupport.rule(
        id: 101,
        action: .filter(.allow),
        reviewState: .reviewed
    )
    let unreviewed = try RuleTestSupport.rule(
        id: 100,
        action: .filter(.allow),
        reviewState: .unreviewed
    )
    let decision = ReferenceRuleMatcher(rules: [reviewed, unreviewed]).decision(
        for: try RuleTestSupport.flow(),
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(100))
    #expect(decision.issues.contains(DecisionIssue(category: .filter, reason: .ambiguousPrecedence)))
}

@Test func smallerSetsAndFewerDomainLabelsWinWithinDestinationType() throws {
    let api = try DomainName("api.sub.example.com")
    let other = try DomainName("other.example.com")
    let smallSet = try RuleTestSupport.rule(
        id: 110,
        action: .filter(.allow),
        destination: .normalizedExactHostnameSet([api])
    )
    let largeSet = try RuleTestSupport.rule(
        id: 111,
        action: .filter(.deny),
        destination: .normalizedExactHostnameSet([api, other])
    )
    let exactDecision = ReferenceRuleMatcher(rules: [largeSet, smallSet]).decision(
        for: try RuleTestSupport.flow(
            remote: RuleTestSupport.endpoint(hostname: api.ascii),
            observedHostname: .some(api)
        ),
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(exactDecision.filter.action == .allow)

    let fewerLabels = try RuleTestSupport.rule(
        id: 112,
        action: .filter(.allow),
        destination: .normalizedDomainSet([try DomainName("example.com")])
    )
    let moreLabels = try RuleTestSupport.rule(
        id: 113,
        action: .filter(.deny),
        destination: .normalizedDomainSet([try DomainName("sub.example.com")])
    )
    let domainDecision = ReferenceRuleMatcher(rules: [moreLabels, fewerLabels]).decision(
        for: try RuleTestSupport.flow(
            remote: RuleTestSupport.endpoint(hostname: api.ascii),
            observedHostname: .some(api)
        ),
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(domainDecision.filter.action == .allow)
}

@Test func ownerDirectionAndFilterActionResolveInDocumentedOrder() throws {
    let rules = [
        try RuleTestSupport.rule(id: 120, action: .filter(.deny)),
        try RuleTestSupport.rule(
            id: 121,
            action: .filter(.allow),
            direction: .outgoing,
            owner: .specificUser(uid: 501)
        ),
    ]
    let decision = ReferenceRuleMatcher(rules: rules).decision(
        for: try RuleTestSupport.flow(),
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(121))

    let deny = try RuleTestSupport.rule(id: 122, action: .filter(.deny))
    let allow = try RuleTestSupport.rule(id: 123, action: .filter(.allow))
    #expect(ReferenceRuleMatcher(rules: [allow, deny]).decision(
        for: try RuleTestSupport.flow(),
        context: RuleTestSupport.context(),
        mode: .alert
    ).filter.action == .deny)
}

@Test func foreignAndSystemOwnersNeverMatchAuthorizedUserRules() throws {
    let userRule = try RuleTestSupport.rule(id: 130, action: .filter(.deny))
    let systemRule = try RuleTestSupport.rule(
        id: 131,
        action: .filter(.deny),
        owner: .system
    )
    let matcher = ReferenceRuleMatcher(rules: [userRule, systemRule])
    #expect(matcher.decision(
        for: try RuleTestSupport.flow(owner: .user(uid: 502)),
        context: RuleTestSupport.context(),
        mode: .silentAllow
    ).filter.action == .allow)
    #expect(matcher.decision(
        for: try RuleTestSupport.flow(owner: .system),
        context: RuleTestSupport.context(),
        mode: .silentAllow
    ).filter.winningRuleID == RuleTestSupport.uuid(131))
}

@Test func filterOffAlwaysAllowsWhileRetainingCoverageEvidence() throws {
    let deny = try RuleTestSupport.rule(id: 140, action: .filter(.deny))
    let decision = ReferenceRuleMatcher(rules: [deny]).decision(
        for: try RuleTestSupport.flow(),
        context: RuleTestSupport.context(),
        mode: .filterOff
    )
    #expect(decision.filter.action == .allow)
    #expect(decision.filter.winningRuleID == nil)
    #expect(decision.filter.affectingRuleIDs == [deny.id])
}

@Test func overlappingEndpointClassesUseFixedClassPrecedence() throws {
    let endpoint = try RuleTestSupport.endpoint(
        address: "224.0.0.251",
        hostname: "printer.local",
        classes: [.broadcast, .multicast, .bonjour, .localNetwork]
    )
    let rules = [
        try RuleTestSupport.rule(id: 150, action: .filter(.allow), destination: .endpointClass(.broadcast)),
        try RuleTestSupport.rule(id: 151, action: .filter(.deny), destination: .endpointClass(.multicast)),
        try RuleTestSupport.rule(id: 152, action: .filter(.deny), destination: .endpointClass(.bonjour)),
        try RuleTestSupport.rule(id: 153, action: .filter(.deny), destination: .endpointClass(.localNetwork)),
    ]
    let decision = ReferenceRuleMatcher(rules: rules).decision(
        for: try RuleTestSupport.flow(remote: endpoint),
        context: RuleTestSupport.context(),
        mode: .alert
    )
    #expect(decision.filter.winningRuleID == RuleTestSupport.uuid(150))
}

import AbyssControl
import AbyssCore
import AbyssIPC
import Foundation
import Testing

@Test func destinationEditorNormalizesAndRejectsMixedTypes() throws {
    let parsed = try DestinationEditorParser.parse(
        "203.0.113.8, 203.0.113.8\n203.0.113.0/24",
        domainsIncludeChildren: false
    )
    guard case .ipSet(let values) = parsed else { Issue.record("Expected IP set"); return }
    #expect(values.count == 2)
    #expect(throws: DestinationEditorError.mixedTypes) {
        try DestinationEditorParser.parse("example.test, 203.0.113.8", domainsIncludeChildren: false)
    }
}

@Test func destinationEditorKeepsManualHostnamesExactUntilPSLValidationExists() throws {
    let destination = try DestinationEditorParser.parse(
        "api.example.test, cdn.example.test",
        domainsIncludeChildren: false
    )
    guard case .exactHostnameSet(let values) = destination else {
        Issue.record("Expected exact hostnames")
        return
    }
    #expect(values.map(\.ascii) == ["api.example.test", "cdn.example.test"])
    #expect(throws: DestinationEditorError.childDomainsUnavailable) {
        try DestinationEditorParser.parse(
            "example.test",
            domainsIncludeChildren: true
        )
    }
}

@Test func workspaceFiltersTemporaryDeniedRules() throws {
    let lineage = UUID()
    let now = Date()
    let rule = try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: .normal,
        process: .anyProcess,
        destination: .normalizedExactHostnameSet([try DomainName("example.test")]),
        transportProtocol: .tcp, port: try PortRange(443, 443), direction: .outgoing,
        owner: .authorizedUser, expiresAt: now.addingTimeInterval(60),
        createdAt: now, modifiedAt: now
    )
    #expect(RuleWorkspaceQuery.rows(
        rules: [rule], state: .enforced, generation: 2, filter: .denied, search: "example"
    ).count == 1)
    #expect(RuleWorkspaceQuery.rows(
        rules: [rule], state: .enforced, generation: 2, filter: .unreviewed, search: ""
    ).isEmpty)
    let usage = RuleUsageValue(lowerBoundCount: 3, lastUsedAt: now, coverage: .partial)
    let recentlyUsed = RuleWorkspaceQuery.rows(
        rules: [rule], state: .enforced, generation: 2, filter: .recentlyUsed,
        search: "", usage: [rule.id: usage]
    )
    #expect(recentlyUsed.first?.usage.lowerBoundCount == 3)
    #expect(recentlyUsed.first?.usage.coverage == .partial)
}

@Test func workspaceActiveFilterUsesProfileGroupEnabledAndExpiryContext() throws {
    let now = Date(timeIntervalSince1970: 10_000)
    let activeProfileID = UUID()
    let inactiveProfileID = UUID()
    let enabledGroupID = UUID()
    let disabledGroupID = UUID()
    let always = try workspaceRule(now: now)
    let disabled = try workspaceRule(isEnabled: false, now: now)
    let activeProfile = try workspaceRule(profileID: activeProfileID, now: now)
    let inactiveProfile = try workspaceRule(profileID: inactiveProfileID, now: now)
    let enabledGroup = try workspaceRule(groupID: enabledGroupID, now: now)
    let disabledGroup = try workspaceRule(groupID: disabledGroupID, now: now)
    let future = try workspaceRule(expiresAt: now.addingTimeInterval(1), now: now)
    let expired = try workspaceRule(expiresAt: now, now: now)
    let fullyScoped = try workspaceRule(
        profileID: activeProfileID,
        groupID: enabledGroupID,
        expiresAt: now.addingTimeInterval(60),
        now: now
    )
    let rules = [
        always, disabled, activeProfile, inactiveProfile, enabledGroup, disabledGroup,
        future, expired, fullyScoped,
    ]
    let context = RuleWorkspaceQueryContext(
        activeProfileID: activeProfileID,
        enabledLocalGroupIDs: [enabledGroupID],
        now: now
    )
    let activeIDs = Set(RuleWorkspaceQuery.rows(
        rules: rules,
        state: .enforced,
        generation: 1,
        filter: .active,
        search: "",
        context: context
    ).map(\.id))
    #expect(activeIDs == Set([
        always.id, activeProfile.id, enabledGroup.id, future.id, fullyScoped.id,
    ]))
    #expect(RuleWorkspaceQuery.rows(
        rules: rules,
        state: .enforced,
        generation: 1,
        filter: .active,
        search: ""
    ).isEmpty)
}

@Test func workspaceSnapshotBuildsActiveContextFromConfigurationAtInjectedTime() throws {
    let now = Date(timeIntervalSince1970: 20_000)
    let profileID = UUID()
    let groupID = UUID()
    let active = try workspaceRule(
        profileID: profileID,
        groupID: groupID,
        expiresAt: now.addingTimeInterval(1),
        now: now
    )
    let expired = try workspaceRule(expiresAt: now, now: now)
    let profile = PolicyProfile(
        id: profileID,
        name: "Work",
        symbolName: nil,
        operationModeOverride: nil,
        createdAt: now,
        modifiedAt: now
    )
    let group = LocalRuleGroup(
        id: groupID,
        name: "Browsers",
        note: "",
        isEnabled: true,
        createdAt: now,
        modifiedAt: now
    )
    let configuration = PolicyConfigurationDraft(
        lineageID: active.lineageID,
        authorizedUID: 501,
        operationMode: .silentAllow,
        activeProfileID: profileID,
        enabledLocalGroupIDs: [groupID],
        rules: [active, expired],
        localGroups: [group],
        profiles: [profile]
    )
    let snapshot = RuleWorkspaceSnapshot(
        configuration: configuration,
        enforcementState: .enforced,
        desiredTuple: PolicyTuple(
            lineageID: configuration.lineageID,
            generation: 1,
            hash: Data(repeating: 1, count: 32)
        ),
        generation: 1,
        usage: [:]
    )
    #expect(snapshot.rows(filter: .active, search: "", now: now).map(\.id) == [active.id])
}

@Test func workspaceSearchFindsEveryPresentedRuleFieldWithinItsScope() throws {
    let now = Date(timeIntervalSince1970: 30_000)
    let profileID = UUID()
    let groupID = UUID()
    let identity = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAMID1234",
        signingIdentifier: "com.example.MailClient"
    ))
    let rule = try queryRule(
        action: .filter(.deny),
        process: .exact(identity),
        destination: .normalizedIPSet([
            IPInterval(exact: try IPAddress("203.0.113.53")),
        ]),
        transport: .udp,
        port: try PortRange(5_353, 5_353),
        direction: .incoming,
        owner: .system,
        profileID: profileID,
        groupID: groupID,
        source: .imported,
        note: "Review DNS helper",
        now: now
    )
    let context = RuleWorkspaceQueryContext(
        activeProfileID: profileID,
        enabledLocalGroupIDs: [groupID],
        localGroupNames: [groupID: "Browser Helpers"],
        profileNames: [profileID: "Work"],
        now: now
    )
    func ids(_ search: String, scope: RuleSearchScope) -> [UUID] {
        RuleWorkspaceQuery.rows(
            rules: [rule], state: .enforced, generation: 4, filter: .all,
            search: search, searchScope: scope, context: context
        ).map(\.id)
    }

    #expect(ids("example mailclient", scope: .application) == [rule.id])
    #expect(ids("203.0.113.53 5353 udp incoming", scope: .match) == [rule.id])
    #expect(ids("system work browser imported", scope: .scope) == [rule.id])
    #expect(ids("dns review", scope: .notes) == [rule.id])
    #expect(ids("mailclient work dns", scope: .all) == [rule.id])
    #expect(ids("work", scope: .match).isEmpty)
    #expect(ids("mailclient", scope: .notes).isEmpty)
}

@Test func workspaceActionFilterComposesWithSidebarFilter() throws {
    let now = Date(timeIntervalSince1970: 31_000)
    let allow = try queryRule(action: .filter(.allow), now: now)
    let deny = try queryRule(action: .filter(.deny), now: now)
    let ask = try queryRule(action: .filter(.ask), now: now)
    let notify = try queryRule(action: .notification(.notify), now: now)
    let hide = try queryRule(action: .privacy(.hide), now: now)
    let rules = [allow, deny, ask, notify, hide]

    #expect(RuleWorkspaceQuery.rows(
        rules: rules, state: .enforced, generation: 1, filter: .all,
        search: "", actionFilter: .notify
    ).map(\.id) == [notify.id])
    #expect(RuleWorkspaceQuery.rows(
        rules: rules, state: .enforced, generation: 1, filter: .all,
        search: "", actionFilter: .hide
    ).map(\.id) == [hide.id])
    #expect(RuleWorkspaceQuery.rows(
        rules: rules, state: .enforced, generation: 1, filter: .denied,
        search: "", actionFilter: .allow
    ).isEmpty)
    #expect(Set(RuleWorkspaceQuery.rows(
        rules: rules, state: .enforced, generation: 1, filter: .all,
        search: "", actionFilter: .all
    ).map(\.id)) == Set(rules.map(\.id)))
}

@Test func workspaceCollectionFiltersComposeWithSearchAndActions() throws {
    let now = Date(timeIntervalSince1970: 31_500)
    let profileID = UUID()
    let groupID = UUID()
    let blocklistID = UUID()
    let profileRule = try queryRule(
        action: .filter(.allow),
        profileID: profileID,
        note: "Profile target",
        now: now
    )
    let groupRule = try queryRule(
        action: .filter(.deny),
        groupID: groupID,
        note: "Group target",
        now: now
    )
    let blocklistRule = try queryRule(
        action: .filter(.deny),
        priority: .blocklistDeny,
        process: .anyProcess,
        destination: .normalizedExactHostnameSet([try DomainName("blocked.example")]),
        transport: .anySupportedProtocol,
        port: nil,
        direction: .bidirectional,
        flags: [.sourceManaged],
        source: .blocklist(sourceID: blocklistID),
        now: now
    )
    let rules = [profileRule, groupRule, blocklistRule]

    #expect(RuleWorkspaceQuery.rows(
        rules: rules, state: .enforced, generation: 1, filter: .all,
        search: "target", actionFilter: .allow, collection: .profile(profileID)
    ).map(\.id) == [profileRule.id])
    #expect(RuleWorkspaceQuery.rows(
        rules: rules, state: .enforced, generation: 1, filter: .denied,
        search: "group", collection: .localGroup(groupID)
    ).map(\.id) == [groupRule.id])
    #expect(RuleWorkspaceQuery.rows(
        rules: rules, state: .enforced, generation: 1, filter: .all,
        search: "blocked", collection: .blocklist(blocklistID)
    ).map(\.id) == [blocklistRule.id])
    #expect(RuleWorkspaceQuery.rows(
        rules: rules, state: .enforced, generation: 1, filter: .all,
        search: "", collection: .profile(UUID())
    ).isEmpty)
}

@Test func workspaceSortingIsStableAndUsesTruthfulUsageOrder() throws {
    let now = Date(timeIntervalSince1970: 32_000)
    let alphaID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let zetaID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
    let alphaIdentity = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAMID1234",
        signingIdentifier: "Alpha"
    ))
    let zetaIdentity = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAMID1234",
        signingIdentifier: "Zeta"
    ))
    let alpha = try queryRule(
        id: alphaID,
        process: .exact(alphaIdentity),
        modifiedAt: now,
        now: now
    )
    let zeta = try queryRule(
        id: zetaID,
        process: .exact(zetaIdentity),
        modifiedAt: now.addingTimeInterval(10),
        now: now
    )
    let usage = [
        alpha.id: RuleUsageValue(lowerBoundCount: 2, lastUsedAt: now, coverage: .complete),
        zeta.id: RuleUsageValue(lowerBoundCount: 9, lastUsedAt: now, coverage: .partial),
    ]

    #expect(RuleWorkspaceQuery.rows(
        rules: [zeta, alpha], state: .enforced, generation: 1, filter: .all,
        search: "", sort: .application, usage: usage
    ).map(\.id) == [alpha.id, zeta.id])
    #expect(RuleWorkspaceQuery.rows(
        rules: [alpha, zeta], state: .enforced, generation: 1, filter: .all,
        search: "", sort: .modified, usage: usage
    ).map(\.id) == [zeta.id, alpha.id])
    #expect(RuleWorkspaceQuery.rows(
        rules: [alpha, zeta], state: .enforced, generation: 1, filter: .all,
        search: "", sort: .usage, usage: usage
    ).map(\.id) == [zeta.id, alpha.id])
}

@Test func interactiveEditCanCreateDeliberateBlocklistException() throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let identity = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAMID1234",
        signingIdentifier: "com.example.client"
    ))
    let destination = try DestinationCondition.normalizedExactHostnameSet([
        DomainName("api.example.com"),
    ])
    let rule = try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(.allow), priority: .normal,
        process: .anyProcess, destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol, port: nil, direction: .outgoing,
        owner: .authorizedUser, createdAt: now, modifiedAt: now
    )
    let edited = try RuleMutation.edited(
        rule,
        action: .filter(.allow),
        priority: .elevatedUser,
        process: .exact(identity),
        destination: destination,
        transport: rule.transportProtocol,
        port: rule.port,
        direction: rule.direction,
        owner: rule.owner,
        profileID: rule.profileID,
        localGroupID: rule.localGroupID,
        expiresAt: rule.expiresAt,
        isEnabled: rule.isEnabled,
        reviewState: rule.reviewState,
        note: rule.notes,
        now: now.addingTimeInterval(1)
    )
    #expect(edited.priority == .elevatedUser)
    #expect(edited.revision == 2)
}

@Test func interactiveEditAppliesEveryMutableManualCondition() throws {
    let now = Date(timeIntervalSince1970: 2_000)
    let profileID = UUID()
    let groupID = UUID()
    let identity = ProcessIdentity.developerID(try SignedCodeIdentity(
        teamIdentifier: "TEAMID1234",
        signingIdentifier: "com.example.client"
    ))
    let rule = try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(.allow), priority: .normal,
        process: .anyProcess, destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol, port: nil, direction: .outgoing,
        owner: .authorizedUser, createdAt: now, modifiedAt: now
    )
    let destination = try DestinationCondition.normalizedIPSet([
        IPInterval(exact: try IPAddress("203.0.113.9"))
    ])
    let dnsPort = try PortRange(53, 53)
    let edited = try RuleMutation.edited(
        rule,
        action: .notification(.notify),
        priority: .normal,
        process: .exact(identity),
        destination: destination,
        transport: .udp,
        port: dnsPort,
        direction: .bidirectional,
        owner: .system,
        profileID: profileID,
        localGroupID: groupID,
        expiresAt: now.addingTimeInterval(3_600),
        isEnabled: false,
        reviewState: .unreviewed,
        note: "review DNS helper",
        now: now.addingTimeInterval(1)
    )

    #expect(edited.action == .notification(.notify))
    #expect(edited.process == .exact(identity))
    #expect(edited.destination == destination)
    #expect(edited.transportProtocol == .udp)
    #expect(edited.port == dnsPort)
    #expect(edited.direction == .bidirectional)
    #expect(edited.owner == .system)
    #expect(edited.profileID == profileID)
    #expect(edited.localGroupID == groupID)
    #expect(!edited.isEnabled)
    #expect(edited.reviewState == .unreviewed)
    #expect(edited.notes == "review DNS helper")
}

private func workspaceRule(
    isEnabled: Bool = true,
    profileID: UUID? = nil,
    groupID: UUID? = nil,
    expiresAt: Date? = nil,
    now: Date
) throws -> Rule {
    try Rule(
        id: UUID(),
        lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
        revision: 1,
        action: .filter(.allow),
        priority: .normal,
        process: .anyProcess,
        destination: .anyEndpoint,
        transportProtocol: .anySupportedProtocol,
        port: nil,
        direction: .bidirectional,
        owner: .authorizedUser,
        profileID: profileID,
        localGroupID: groupID,
        expiresAt: expiresAt,
        isEnabled: isEnabled,
        createdAt: now,
        modifiedAt: now
    )
}

private func queryRule(
    id: UUID = UUID(),
    action: RuleAction = .filter(.allow),
    priority: RulePriority = .normal,
    process: ProcessCondition = .anyProcess,
    destination: DestinationCondition = .anyEndpoint,
    transport: ProtocolCondition = .anySupportedProtocol,
    port: PortRange? = nil,
    direction: DirectionCondition = .outgoing,
    owner: OwnerCondition = .authorizedUser,
    profileID: UUID? = nil,
    groupID: UUID? = nil,
    flags: RuleFlags = [],
    source: RuleSource = .manual,
    note: String = "",
    modifiedAt: Date? = nil,
    now: Date
) throws -> Rule {
    try Rule(
        id: id,
        lineageID: UUID(uuidString: "00000000-0000-0000-0000-000000000099")!,
        revision: 1,
        action: action,
        priority: priority,
        process: process,
        destination: destination,
        transportProtocol: transport,
        port: port,
        direction: direction,
        owner: owner,
        profileID: profileID,
        localGroupID: groupID,
        isEnabled: true,
        flags: flags,
        reviewState: .reviewed,
        source: source,
        notes: note,
        createdAt: now,
        modifiedAt: modifiedAt ?? now
    )
}

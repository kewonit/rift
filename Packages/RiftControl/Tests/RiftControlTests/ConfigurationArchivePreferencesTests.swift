import Foundation
import RiftControl
import RiftCore
import Testing

private struct Fixture {
    let draft: PolicyConfigurationDraft
    let blocklistID: UUID
    let profileID: UUID
}

private func fixture() throws -> Fixture {
    let lineage = UUID()
    let blocklist = try BlocklistImportBuilder.build(
        entries: [.domain(try DomainName("example.test"))],
        name: "Subscribed list",
        contentHash: Data(repeating: 7, count: 32),
        lineageID: lineage,
        now: Date(timeIntervalSince1970: 50)
    )
    let profile = PolicyProfile(
        id: UUID(), name: "Home", symbolName: nil, operationModeOverride: nil,
        createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let draft = PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: blocklist.rules,
        profiles: [profile], blocklists: [blocklist.source]
    )
    return Fixture(draft: draft, blocklistID: blocklist.source.id, profileID: profile.id)
}

private func preferences(
    blocklistID: UUID,
    profileID: UUID,
    extraSubscription: UUID? = nil
) throws -> ConfigurationArchivePreferences {
    let url = try BlocklistSubscriptionAddress.validate("https://lists.example.test/hosts.txt")
    var subscriptions = [ArchivedBlocklistSubscription(blocklistID: blocklistID, url: url)]
    if let extraSubscription {
        subscriptions.append(ArchivedBlocklistSubscription(blocklistID: extraSubscription, url: url))
    }
    return ConfigurationArchivePreferences(
        blocklistSubscriptions: subscriptions,
        networkProfiles: ArchivedNetworkProfiles(
            enabled: true, notifies: true, usesWiFiNames: false, otherNetworks: .leaveAsIs,
            remembered: [
                RememberedNetwork(
                    key: "wired:192.0.2.1", name: "Ethernet with router 192.0.2.1",
                    choice: .profile(profileID), lastSeenAt: Date(timeIntervalSince1970: 100)
                ),
                RememberedNetwork(
                    key: "wired:192.0.2.9", name: "Ethernet with router 192.0.2.9",
                    choice: .profile(UUID()), lastSeenAt: Date(timeIntervalSince1970: 100)
                ),
            ]
        ),
        alerts: ArchivedAlertPreferences(
            blocksUnanswered: true, defaultLifetime: "Permanent",
            defaultDestination: "This domain", defaultScope: "All profiles"
        )
    )
}

@Test func preferencesSurviveAnExportAndRestore() throws {
    let fixture = try fixture()
    let bytes = try ConfigurationArchiveCodec.export(
        draft: fixture.draft, appVersion: "1.0", now: Date(timeIntervalSince1970: 200),
        preferences: try preferences(
            blocklistID: fixture.blocklistID, profileID: fixture.profileID, extraSubscription: UUID()
        )
    )
    let restored = try #require(try ConfigurationArchiveCodec.decode(bytes).preferences)
    #expect(restored.blocklistSubscriptions.map(\.blocklistID) == [fixture.blocklistID])
    #expect(restored.alerts.blocksUnanswered)
    #expect(restored.alerts.defaultLifetime == "Always")
    #expect(restored.networkProfiles.enabled)
    let choices = Dictionary(uniqueKeysWithValues: restored.networkProfiles.remembered.map { ($0.key, $0.choice) })
    #expect(choices["wired:192.0.2.1"] == .profile(fixture.profileID))
    // A network chosen for a profile the configuration doesn't have leaves the profile alone.
    #expect(choices["wired:192.0.2.9"] == .leaveAsIs)
}

@Test func anArchiveWithoutPreferencesStillRestores() throws {
    let fixture = try fixture()
    let bytes = try ConfigurationArchiveCodec.export(draft: fixture.draft, appVersion: "1.0", now: Date())
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let payload = try #require(object["payload"] as? [String: Any])
    #expect(payload["preferences"] == nil)
    #expect(try ConfigurationArchiveCodec.decode(bytes).preferences == nil)
}

@Test func schemaThreeArchivesStillRestoreButCantCarryPreferences() throws {
    let fixture = try fixture()
    let plain = try ConfigurationArchiveCodec.export(draft: fixture.draft, appVersion: "1.0", now: Date())
    var object = try #require(JSONSerialization.jsonObject(with: plain) as? [String: Any])
    object["schemaVersion"] = 3
    let version3 = try JSONSerialization.data(withJSONObject: object)
    #expect(try ConfigurationArchiveCodec.decode(version3).rules == fixture.draft.rules)

    let withPreferences = try ConfigurationArchiveCodec.export(
        draft: fixture.draft, appVersion: "1.0", now: Date(),
        preferences: try preferences(blocklistID: fixture.blocklistID, profileID: fixture.profileID)
    )
    object = try #require(JSONSerialization.jsonObject(with: withPreferences) as? [String: Any])
    object["schemaVersion"] = 3
    let mislabelled = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: ConfigurationArchiveError.invalidShape) { try ConfigurationArchiveCodec.decode(mislabelled) }
}

@Test func editedPreferencesAreRejected() throws {
    let fixture = try fixture()
    let valid = try preferences(blocklistID: fixture.blocklistID, profileID: fixture.profileID)
    let profiles: Set<UUID> = [fixture.profileID]
    let blocklists: Set<UUID> = [fixture.blocklistID]
    #expect(valid.sanitized(profileIDs: profiles, blocklistIDs: blocklists)
        .isValid(profileIDs: profiles, blocklistIDs: blocklists))
    // A subscription for a blocklist the archive doesn't hold.
    #expect(!valid.isValid(profileIDs: profiles, blocklistIDs: []))
    // A plain-HTTP address can't come back through a restore.
    var insecure = valid.sanitized(profileIDs: profiles, blocklistIDs: blocklists)
    insecure.blocklistSubscriptions = [ArchivedBlocklistSubscription(
        blocklistID: fixture.blocklistID, url: try #require(URL(string: "http://lists.example.test/hosts.txt"))
    )]
    #expect(!insecure.isValid(profileIDs: profiles, blocklistIDs: blocklists))
}

private func groupFixture() throws -> (PolicyConfigurationDraft, UUID) {
    let base = try fixture().draft
    let group = LocalRuleGroup(
        id: UUID(), name: "Shared rules", note: "", isEnabled: true,
        createdAt: Date(timeIntervalSince1970: 1), modifiedAt: Date(timeIntervalSince1970: 1)
    )
    let draft = PolicyConfigurationDraft(
        lineageID: base.lineageID, authorizedUID: 501, operationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [group.id], rules: base.rules,
        localGroups: [group], profiles: base.profiles, blocklists: base.blocklists
    )
    return (draft, group.id)
}

@Test func archivesWithoutRuleGroupSubscriptionsKeepTheirShape() throws {
    let fixture = try fixture()
    let bytes = try ConfigurationArchiveCodec.export(
        draft: fixture.draft, appVersion: "1.0", now: Date(timeIntervalSince1970: 200),
        preferences: try preferences(blocklistID: fixture.blocklistID, profileID: fixture.profileID)
    )
    let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    let payload = try #require(object["payload"] as? [String: Any])
    let saved = try #require(payload["preferences"] as? [String: Any])
    #expect(Set(saved.keys) == ["blocklistSubscriptions", "networkProfiles", "alerts"])
    #expect(try ConfigurationArchiveCodec.decode(bytes).preferences?.ruleGroupSubscriptions == nil)
}

@Test func ruleGroupSubscriptionsSurviveARestore() throws {
    let (draft, groupID) = try groupFixture()
    let url = try BlocklistSubscriptionAddress.validate("https://rules.example.test/shared.lsrules")
    var withGroups = try preferences(blocklistID: draft.blocklists[0].id, profileID: draft.profiles[0].id)
    let kept = ArchivedRuleGroupSubscription(groupID: groupID, url: url, interval: .weekly, holdsNewAllowRules: false)
    // A subscription for a group the configuration doesn't have is dropped.
    withGroups.ruleGroupSubscriptions = [kept, ArchivedRuleGroupSubscription(groupID: UUID(), url: url)]
    let bytes = try ConfigurationArchiveCodec.export(
        draft: draft, appVersion: "1.0", now: Date(timeIntervalSince1970: 200), preferences: withGroups
    )
    let restored = try #require(try ConfigurationArchiveCodec.decode(bytes).preferences?.ruleGroupSubscriptions)
    #expect(restored == [kept])
    let subscription = RuleGroupSubscription(restoring: restored[0])
    #expect(!subscription.holdsNewAllowRules)
    #expect(subscription.effectiveInterval == .weekly)

    // Defaults are left out, and a plain-HTTP address can't come back.
    #expect(ArchivedRuleGroupSubscription(groupID: groupID, url: url).allowsNewAllowRules == nil)
    let profiles = Set(draft.profiles.map(\.id))
    let blocklists = Set(draft.blocklists.map(\.id))
    var insecure = withGroups.sanitized(profileIDs: profiles, blocklistIDs: blocklists, groupIDs: [groupID])
    insecure.ruleGroupSubscriptions = [ArchivedRuleGroupSubscription(
        groupID: groupID, url: try #require(URL(string: "http://rules.example.test/shared.lsrules"))
    )]
    #expect(!insecure.isValid(profileIDs: profiles, blocklistIDs: blocklists, groupIDs: [groupID]))
}

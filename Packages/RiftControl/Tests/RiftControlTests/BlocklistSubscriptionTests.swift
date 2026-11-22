import CryptoKit
import Foundation
import RiftCore
import Testing
@testable import RiftControl

@Test func subscriptionsAcceptOnlyPlainHTTPSAddresses() throws {
    #expect(try BlocklistSubscriptionAddress.validate(" https://lists.example/ads.txt ").absoluteString
        == "https://lists.example/ads.txt")
    #expect(throws: BlocklistSubscriptionError.insecureAddress) {
        try BlocklistSubscriptionAddress.validate("http://lists.example/ads.txt")
    }
    #expect(throws: BlocklistSubscriptionError.credentialsInAddress) {
        try BlocklistSubscriptionAddress.validate("https://me:secret@lists.example/ads.txt")
    }
    #expect(throws: BlocklistSubscriptionError.invalidAddress) {
        try BlocklistSubscriptionAddress.validate("lists.example/ads.txt")
    }
    #expect(throws: BlocklistSubscriptionError.invalidAddress) {
        try BlocklistSubscriptionAddress.validate("https://")
    }
}

@Test func subscriptionsAreCheckedDailyAndRetriedHourlyAfterAFailure() throws {
    let start = Date(timeIntervalSince1970: 1_000_000)
    var item = BlocklistSubscription(id: UUID(), url: URL(string: "https://lists.example/a")!)
    #expect(item.isDue(now: start))
    item.lastCheckedAt = start
    #expect(!item.isDue(now: start.addingTimeInterval(23 * 3_600)))
    #expect(item.isDue(now: start.addingTimeInterval(24 * 3_600)))
    item.lastFailure = "The server answered with error 503."
    #expect(item.isDue(now: start.addingTimeInterval(3_600)))
    #expect(!item.isDue(now: start.addingTimeInterval(59 * 60)))
}

@Test func anUpdatedListKeepsItsIdentityAndWhetherItsOn() throws {
    let id = UUID()
    let lineage = UUID()
    let preparation = try BlocklistImportBuilder.prepare(
        entries: [.domain(try DomainName("ads.example")), .address(IPInterval(exact: try IPAddress("203.0.113.8")))],
        name: "Ads",
        contentHash: Data(SHA256.hash(data: Data("v2".utf8)))
    )
    let result = try BlocklistImportBuilder.build(
        preparation: preparation, lineageID: lineage, now: Date(timeIntervalSince1970: 5),
        sourceID: id, status: .disabled
    )
    #expect(result.source.id == id)
    #expect(result.source.status == .disabled)
    #expect(result.rules.allSatisfy { !$0.isEnabled && $0.source == .blocklist(sourceID: id) })
    let draft = PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow, baseOperationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [], rules: result.rules, localGroups: [], profiles: [],
        blocklists: [result.source]
    )
    try PolicyConfigurationValidator.validate(draft)
}

@Test func theMacOSServicesGroupIsValidAndOnlyAllowsAppleCode() throws {
    let lineage = UUID()
    let made = try BuiltInRuleGroups.macOSServices(lineageID: lineage, now: Date(timeIntervalSince1970: 9))
    #expect(made.rules.count == (BuiltInRuleGroups.appleServices.count + 2) * 2)
    #expect(made.rules.allSatisfy { rule in
        guard case .exact(.applePlatform) = rule.process else { return false }
        return rule.action == .filter(.allow) && rule.direction == .outgoing
            && rule.localGroupID == made.group.id && rule.source == .manual
    })
    let draft = PolicyConfigurationDraft(
        lineageID: lineage, authorizedUID: 501, operationMode: .silentAllow, baseOperationMode: .silentAllow,
        activeProfileID: nil, enabledLocalGroupIDs: [made.group.id], rules: made.rules,
        localGroups: [made.group], profiles: [], blocklists: []
    )
    try PolicyConfigurationValidator.validate(draft)
    // A full export of a configuration with the group still restores.
    let archive = try ConfigurationArchiveCodec.export(draft: draft, appVersion: "test", now: Date())
    #expect(try ConfigurationArchiveCodec.decode(archive).rules.count == made.rules.count)
}

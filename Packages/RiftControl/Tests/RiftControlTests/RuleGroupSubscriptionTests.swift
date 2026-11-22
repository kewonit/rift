import Foundation
import RiftCore
import Testing
@testable import RiftControl

private let notes = ProcessIdentity.developerID(
    try! SignedCodeIdentity(teamIdentifier: "TEAM123456", signingIdentifier: "com.example.notes")
)
private let groupID = UUID()
private let start = Date(timeIntervalSince1970: 1_000)

private func incoming(_ action: FilterAction, _ host: String, high: Bool = false, enabled: Bool = true) throws -> Rule {
    try Rule(
        id: UUID(), lineageID: UUID(), revision: 1, action: .filter(action),
        priority: high ? .elevatedUser : .normal, process: .exact(notes),
        destination: .normalizedExactHostnameSet([DomainName(host)]), transportProtocol: .anySupportedProtocol,
        port: nil, direction: .outgoing, owner: .authorizedUser, localGroupID: UUID(),
        isEnabled: enabled, reviewState: .unreviewed, source: .imported, createdAt: start, modifiedAt: start
    )
}

private func merge(_ current: [Rule], _ new: [Rule], holds: Bool = true, first: Bool = false) throws -> RuleGroupSubscriptionMerge {
    try RuleGroupSubscriptionMerge.merge(
        current: current, incoming: new, groupID: groupID,
        holdsNewAllowRules: holds, isFirstVersion: first, now: start
    )
}

@Test func theFirstVersionAddsRulesAsTheFileSays() throws {
    let result = try merge([], [try incoming(.allow, "a.example"), try incoming(.deny, "b.example", enabled: false)], first: true)
    #expect(result.added == 2)
    #expect(result.rules.map(\.isEnabled) == [true, false])
    #expect(result.rules.allSatisfy { $0.localGroupID == groupID && $0.source == .imported })
    #expect(result.heldRuleIDs.isEmpty)
}

@Test func anUpdateHoldsNewAllowRulesButNotNewBlockRules() throws {
    let first = try merge([], [try incoming(.allow, "a.example")], first: true)
    let update = try merge(first.rules, [
        try incoming(.allow, "a.example"), try incoming(.allow, "new.example"), try incoming(.deny, "ads.example"),
    ])
    #expect(update.added == 2)
    #expect(update.removed == 0)
    // The rule that was already there is the same rule.
    #expect(update.rules[0] == first.rules[0])
    let held = try #require(update.rules.first { $0.destination == (try .normalizedExactHostnameSet([DomainName("new.example")])) })
    #expect(!held.isEnabled)
    #expect(update.heldRuleIDs == [held.id])
    #expect(update.rules.last?.isEnabled == true)
    #expect(update.summary == "2 rules added, 0 removed, 1 new allow rule is off until you turn it on.")

    let trusting = try merge(first.rules, [try incoming(.allow, "new.example")], holds: false)
    #expect(trusting.rules.first?.isEnabled == true)
    #expect(trusting.removed == 1)
}

@Test func highPriorityRulesAreAlwaysHeldAndTheirChoicesKept() throws {
    let first = try merge([], [try incoming(.allow, "a.example", high: true)], first: true)
    #expect(first.rules.first?.isEnabled == false)
    #expect(first.heldRuleIDs.count == 1)
    // A rule the person turned off stays off when the file still has it.
    let mine = try merge([], [try incoming(.deny, "b.example")], first: true).rules
    let turnedOff = try RuleMutation.enabled(mine[0], value: false, now: start)
    let again = try merge([turnedOff], [try incoming(.deny, "b.example")])
    #expect(again.rules == [turnedOff])
    #expect(!again.changed)
    #expect(again.summary == "The rule group is up to date.")
}

@Test func pendingRulesAreThoseStillHeldAndOff() throws {
    var subscription = RuleGroupSubscription(id: groupID, url: try BlocklistSubscriptionAddress.validate("https://rules.example/a.lsrules"))
    let update = try merge(try merge([], [], first: true).rules, [try incoming(.allow, "new.example"), try incoming(.allow, "two.example")])
    subscription.notePending(held: update.heldRuleIDs, groupRules: update.rules)
    #expect(subscription.pendingRuleIDs.count == 2)
    let approved = try update.rules.map { try RuleMutation.enabled($0, value: $0.id == update.rules[0].id, now: start) }
    subscription.notePending(groupRules: approved)
    #expect(subscription.pendingRuleIDs == [update.rules[1].id])
    subscription.notePending(groupRules: [])
    #expect(subscription.pendingRuleIDs.isEmpty)
}

@Test func checkingIsDueOnTheChosenInterval() throws {
    let url = try BlocklistSubscriptionAddress.validate("https://rules.example/a.lsrules")
    var subscription = RuleGroupSubscription(id: groupID, url: url, interval: .weekly, lastCheckedAt: start)
    #expect(!subscription.isDue(now: start.addingTimeInterval(86_400)))
    #expect(subscription.isDue(now: start.addingTimeInterval(8 * 86_400)))
    subscription.lastFailure = "The server answered with error 500."
    #expect(subscription.isDue(now: start.addingTimeInterval(3_600)))
}

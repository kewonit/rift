import RiftCore
@testable import RiftFilterRuntime
import Foundation
import Testing

@Test func interactivePolicyRequiresTheCurrentOwnerSession() {
    #expect(ConsoleSessionPolicy.permitsInteractivePolicy(
        authorizedUID: 501,
        currentConsoleUID: 501,
        flowOwner: .user(uid: 501)
    ))
    #expect(ConsoleSessionPolicy.permitsInteractivePolicy(
        authorizedUID: 501,
        currentConsoleUID: 501,
        flowOwner: .system
    ))
    #expect(!ConsoleSessionPolicy.permitsInteractivePolicy(
        authorizedUID: 501,
        currentConsoleUID: 502,
        flowOwner: .user(uid: 501)
    ))
    #expect(!ConsoleSessionPolicy.permitsInteractivePolicy(
        authorizedUID: 501,
        currentConsoleUID: 501,
        flowOwner: .user(uid: 502)
    ))
    #expect(!ConsoleSessionPolicy.permitsInteractivePolicy(
        authorizedUID: 501,
        currentConsoleUID: nil,
        flowOwner: .system
    ))
    #expect(!ConsoleSessionPolicy.permitsInteractivePolicy(
        authorizedUID: 501,
        currentConsoleUID: 501,
        flowOwner: .unknown
    ))
}

private let allOwners: [FlowOwner] = [.user(uid: 501), .system, .user(uid: 502), .unknown]

private func restricted(_ decision: Decision, _ owner: FlowOwner) -> FilterAction {
    ConsoleSessionPolicy.restrictedAction(for: decision, flowOwner: owner, authorizedUID: 501)
}

@Test func restrictedSessionsEnforceConcreteWinnersForEveryOwner() {
    let ruleID = UUID()
    for owner in allOwners {
        #expect(restricted(decision(.deny, winner: ruleID), owner) == .deny)
        #expect(restricted(decision(.allow, winner: ruleID), owner) == .allow)
        #expect(restricted(decision(.ask, winner: ruleID), owner) == .allow)
    }
}

@Test func restrictedSessionsKeepBlockUnlessAllowedForTheAuthorizedAccountAndRoot() {
    #expect(restricted(decision(.deny, winner: nil), .user(uid: 501)) == .deny)
    #expect(restricted(decision(.deny, winner: nil), .system) == .deny)
}

@Test func restrictedSessionsApplyOnlyExplicitRulesToOtherAccountsAndUnknownOwners() {
    #expect(restricted(decision(.deny, winner: nil), .user(uid: 502)) == .allow)
    #expect(restricted(decision(.deny, winner: nil), .unknown) == .allow)
}

@Test func restrictedSessionsNeverWaitForAnAlert() {
    for owner in allOwners {
        #expect(restricted(decision(.ask, winner: nil), owner) == .allow)
        #expect(restricted(decision(.allow, winner: nil), owner) == .allow)
    }
}

private func decision(_ action: FilterAction, winner: UUID?) -> Decision {
    Decision(
        filter: CategoryDecision(
            action: action,
            winningRuleID: winner,
            affectingRuleIDs: winner.map { [$0] } ?? [],
            explanation: nil
        ),
        notification: CategoryDecision(
            action: .none,
            winningRuleID: nil,
            affectingRuleIDs: [],
            explanation: nil
        ),
        privacy: CategoryDecision(
            action: .visible,
            winningRuleID: nil,
            affectingRuleIDs: [],
            explanation: nil
        ),
        issues: [],
        earliestExpiry: nil
    )
}

@Test func onlyTheAuthorizedAccountAndRootWaitForAnAppIdentityWhenRestricted() {
    #expect(ConsoleSessionPolicy.appliesAccountPolicy(to: .user(uid: 501), authorizedUID: 501))
    #expect(ConsoleSessionPolicy.appliesAccountPolicy(to: .system, authorizedUID: 501))
    #expect(!ConsoleSessionPolicy.appliesAccountPolicy(to: .user(uid: 502), authorizedUID: 501))
    #expect(!ConsoleSessionPolicy.appliesAccountPolicy(to: .unknown, authorizedUID: 501))
}

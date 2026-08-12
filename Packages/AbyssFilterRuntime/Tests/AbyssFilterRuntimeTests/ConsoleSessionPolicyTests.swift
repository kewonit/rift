import AbyssCore
@testable import AbyssFilterRuntime
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

@Test func restrictedSessionsEnforceOnlyConcreteAllowOrDenyWinners() {
    let ruleID = UUID()
    #expect(ConsoleSessionPolicy.restrictedAction(for: decision(.deny, winner: ruleID)) == .deny)
    #expect(ConsoleSessionPolicy.restrictedAction(for: decision(.allow, winner: ruleID)) == .allow)
    #expect(ConsoleSessionPolicy.restrictedAction(for: decision(.ask, winner: ruleID)) == .allow)
    #expect(ConsoleSessionPolicy.restrictedAction(for: decision(.deny, winner: nil)) == .allow)
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

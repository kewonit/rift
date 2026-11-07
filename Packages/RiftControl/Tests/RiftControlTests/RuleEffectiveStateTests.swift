import Foundation
import RiftControl
import RiftCore
import Testing

private let lineage = UUID(uuidString: "A4F31042-EA13-4D42-B307-AB1D70160322")!
private let now = Date(timeIntervalSince1970: 1_000)

private func rule(
    enabled: Bool = true,
    profile: UUID? = nil,
    group: UUID? = nil,
    expires: Date? = nil
) throws -> Rule {
    try Rule(
        id: UUID(), lineageID: lineage, revision: 1, action: .filter(.deny), priority: .normal,
        process: .anyProcess, destination: .anyEndpoint, transportProtocol: .anySupportedProtocol,
        port: nil, direction: .outgoing, owner: .authorizedUser, profileID: profile,
        localGroupID: group, expiresAt: expires, isEnabled: enabled, createdAt: now, modifiedAt: now
    )
}

private func context(profile: UUID? = nil, groups: Set<UUID> = []) -> RuleWorkspaceQueryContext {
    RuleWorkspaceQueryContext(activeProfileID: profile, enabledLocalGroupIDs: groups, now: now)
}

@Test func anEnabledRuleInForceIsActive() throws {
    #expect(RuleEffectiveState.resolve(rule: try rule(), enforcement: .enforced, context: context()) == .active)
}

@Test func aDisabledRuleNeverReadsActive() throws {
    #expect(RuleEffectiveState.resolve(rule: try rule(enabled: false), enforcement: .enforced, context: context()) == .off)
}

@Test func aRuleInAnotherProfileSaysSo() throws {
    let state = RuleEffectiveState.resolve(
        rule: try rule(profile: UUID()), enforcement: .enforced, context: context(profile: UUID())
    )
    #expect(state == .otherProfile)
}

@Test func aRuleInAnOffGroupSaysSo() throws {
    let state = RuleEffectiveState.resolve(rule: try rule(group: UUID()), enforcement: .enforced, context: context())
    #expect(state == .groupOff)
}

@Test func anExpiredRuleSaysSo() throws {
    let state = RuleEffectiveState.resolve(
        rule: try rule(expires: now.addingTimeInterval(-1)), enforcement: .enforced, context: context()
    )
    #expect(state == .expired)
}

@Test func aSavedRuleWaitsForTheFilter() throws {
    let waiting = RuleEffectiveState.resolve(rule: try rule(), enforcement: .savedPendingEnforcement, context: context())
    #expect(waiting == .waitingForFilter)
    let failed = RuleEffectiveState.resolve(rule: try rule(), enforcement: .applyFailed, context: context())
    #expect(failed == .notApplied)
}

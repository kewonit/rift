import RiftControl
import RiftCore
import Testing

@Test func everyChoiceHasADistinctPlainName() {
    let names = OperationMode.choices.map(\.displayName)
    #expect(Set(names).count == OperationMode.choices.count)
    for name in names {
        #expect(!name.contains("Silent"))
        #expect(!name.contains("Observe"))
    }
}

@Test func onlyRiskyModesNeedConfirmation() {
    #expect(OperationMode.silentDeny.needsConfirmation)
    #expect(OperationMode.filterOff.needsConfirmation)
    #expect(!OperationMode.alert.needsConfirmation)
    #expect(!OperationMode.silentAllow.needsConfirmation)
}

@Test func quittingInAskMeWarnsThatConnectionsAreAllowed() {
    #expect(OperationMode.alert.quitMessage.contains("allowed"))
    #expect(OperationMode.alert.quitMessage.contains("can’t ask"))
}

@Test func quittingInBlockModeNeverClaimsConnectionsAreAllowed() {
    #expect(!OperationMode.silentDeny.quitMessage.contains("allowed"))
    #expect(OperationMode.silentDeny.quitMessage.contains("stay blocked"))
}

@Test func theStatusNamesARuleCountOnlyWhenRulesApply() {
    let active = ProtectionStatus.resolve(ProtectionInputs(
        lifecycle: .enabled, controller: .connected(.ready), filterServiceConfirmed: true,
        hasActivePolicy: true, desiredKnown: true, rulesMatchDesired: true, mode: .alert
    ))
    #expect(active.rulesDetail(ruleCount: 3, blocklistCount: 1) == "In effect. 3 rules and 1 blocklist.")
    #expect(active.rulesDetail(ruleCount: 0, blocklistCount: 0) == "In effect. You have no rules yet.")
    #expect(active.rulesDetail(ruleCount: nil, blocklistCount: nil) == "In effect.")
    let setup = ProtectionStatus.resolve(ProtectionInputs(lifecycle: .notInstalled))
    #expect(setup.rulesDetail(ruleCount: 3, blocklistCount: 1) == setup.rulesSummary)
}

@Test func pausedRulesOfferAWayBack() {
    let status = ProtectionStatus.resolve(ProtectionInputs(
        lifecycle: .enabled, controller: .connected(.ready), filterServiceConfirmed: true,
        hasActivePolicy: true, desiredKnown: true, rulesMatchDesired: true, mode: .filterOff
    ))
    #expect(status.action == .resumeRules)
}

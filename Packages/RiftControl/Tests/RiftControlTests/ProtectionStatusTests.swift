import AppKit
import RiftControl
import RiftCore
import RiftIPC
import Testing

private func healthy(
    mode: OperationMode? = .silentAllow,
    readiness: ProviderReadiness = .ready,
    waiting: Int = 0
) -> ProtectionInputs {
    ProtectionInputs(
        lifecycle: .enabled,
        controller: .connected(readiness),
        filterServiceConfirmed: readiness == .ready,
        hasActivePolicy: true,
        desiredKnown: true,
        rulesMatchDesired: true,
        mode: mode,
        waitingPrompts: waiting
    )
}

/// One input for every state the status can report.
private let everyState: [(ProtectionStatus.State, ProtectionInputs)] = {
    var cases: [(ProtectionStatus.State, ProtectionInputs)] = [
        (.preview, ProtectionInputs(isPreview: true)),
        (.cannotFilter, ProtectionInputs(buildCanFilter: false, lifecycle: .notInstalled)),
        (.checking, ProtectionInputs()),
        (.configurationUnreadable, ProtectionInputs(lifecycle: .enabled, configurationUnreadable: true)),
        (.setupNeeded, ProtectionInputs(lifecycle: .notInstalled)),
        (.settingUp, ProtectionInputs(lifecycle: .activating, lifecycleTitle: "Installing…")),
        (.settingUp, ProtectionInputs(lifecycle: .uninstalling)),
        (.needsApproval, ProtectionInputs(lifecycle: .awaitingApproval)),
        (.filterTurnedOff, ProtectionInputs(lifecycle: .disabled)),
        (.lifecycleProblem, ProtectionInputs(lifecycle: .failed(message: "It failed."))),
        (.lifecycleProblem, ProtectionInputs(lifecycle: .denied(message: "It was denied."))),
        (.connecting, ProtectionInputs(lifecycle: .enabled, controller: .starting)),
        (.connecting, ProtectionInputs(lifecycle: .enabled, controller: .connected(.starting))),
        (.unreachable, ProtectionInputs(lifecycle: .enabled, controller: .unreachable)),
        (.unreachable, ProtectionInputs(lifecycle: .enabled, controller: .failed)),
        (.allowingEverything, ProtectionInputs(lifecycle: .enabled, controller: .connected(.degradedNoPolicy))),
        (.waiting(2), healthy(waiting: 2)),
    ]
    var atRisk = healthy(readiness: .degradedPersistence)
    atRisk.hasActivePolicy = true
    cases.append((.rulesAtRisk, atRisk))
    var notCurrent = healthy()
    notCurrent.rulesMatchDesired = false
    notCurrent.filterServiceConfirmed = false
    cases.append((.rulesNotCurrent, notCurrent))
    cases.append((.modeUnknown, healthy(mode: nil)))
    cases.append((.modeUnknown, healthy(mode: .degradedFallback)))
    for mode: OperationMode in [.alert, .silentAllow, .silentDeny, .filterOff] {
        cases.append((.active(mode), healthy(mode: mode)))
    }
    return cases
}()

@Test func everyInputResolvesToItsExpectedState() {
    for (state, input) in everyState {
        #expect(ProtectionStatus.resolve(input).state == state)
    }
}

@Test func greenMeansSomethingCanActuallyBeBlocked() {
    for (state, input) in everyState {
        let status = ProtectionStatus.resolve(input)
        let canBlockByDefault = state == .active(.alert) || state == .active(.silentDeny)
        #expect((status.tone == .good) == canBlockByDefault)
    }
}

@Test func noStatusClaimsProtection() {
    for (_, input) in everyState {
        let status = ProtectionStatus.resolve(input)
        #expect(!status.title.lowercased().contains("protect"))
        #expect(!status.detail.lowercased().contains("protect"))
    }
}

@Test func allConnectionsIsOnlySaidWhenThatsTrue() {
    for (_, input) in everyState {
        let status = ProtectionStatus.resolve(input)
        let text = (status.title + " " + status.detail).lowercased()
        if text.contains("all connections") { #expect(status.traffic == .allAllowed) }
    }
}

@Test func everyProblemOffersAWayForward() {
    for (_, input) in everyState {
        let status = ProtectionStatus.resolve(input)
        if status.tone == .attention { #expect(status.action != nil) }
    }
}

@Test func theDefaultInstallDoesNotClaimToBlock() {
    let status = ProtectionStatus.resolve(healthy(mode: .silentAllow))
    #expect(status.title == "Rift is watching")
    #expect(status.tone == .neutral)
}

@Test func pausedRulesAreNotPresentedAsWorking() {
    let status = ProtectionStatus.resolve(healthy(mode: .filterOff))
    #expect(status.tone == .neutral)
    #expect(status.traffic == .allAllowed)
    #expect(status.rulesSummary == "Off.")
}

@Test func persistenceFailureWithoutAPolicyAllowsEverything() {
    var input = healthy(readiness: .degradedPersistence)
    input.hasActivePolicy = false
    #expect(ProtectionStatus.resolve(input).state == .allowingEverything)
}

@Test func anUnavailableProviderDependsOnWhetherAPolicyIsLoaded() {
    var input = healthy(readiness: .unavailable)
    #expect(ProtectionStatus.resolve(input).state == .unreachable)
    input.hasActivePolicy = false
    #expect(ProtectionStatus.resolve(input).state == .allowingEverything)
}

@Test func anUnreadableConfigurationSaysWhetherOldRulesStillApply() {
    let kept = ProtectionStatus.resolve(ProtectionInputs(
        lifecycle: .enabled, hasActivePolicy: true, configurationUnreadable: true
    ))
    #expect(kept.traffic == .rulesApply)
    #expect(kept.detail.contains("last working rules"))
    let lost = ProtectionStatus.resolve(ProtectionInputs(
        lifecycle: .enabled, configurationUnreadable: true
    ))
    #expect(lost.traffic == .unknown)
}

@Test func aFailureThatAlreadyStatesTheEffectIsNotRepeated() {
    let message = "macOS couldn’t turn on the filter, so connections aren’t being filtered."
    let status = ProtectionStatus.resolve(ProtectionInputs(lifecycle: .failed(message: message)))
    #expect(status.detail == message)
}

@Test func theMapOnlyInterruptsForThingsThatNeedAttention() {
    #expect(ProtectionStatus.resolve(ProtectionInputs(lifecycle: .notInstalled)).showsBanner)
    #expect(ProtectionStatus.resolve(ProtectionInputs(lifecycle: .disabled)).showsBanner)
    #expect(!ProtectionStatus.resolve(healthy()).showsBanner)
    #expect(!ProtectionStatus.resolve(healthy(waiting: 1)).showsBanner)
    #expect(!ProtectionStatus.resolve(ProtectionInputs(isPreview: true)).showsBanner)
}

@Test func everyStatusSymbolExists() {
    for (_, input) in everyState {
        let status = ProtectionStatus.resolve(input)
        #expect(NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil) != nil)
        if status.tone != .preview {
            #expect(NSImage(systemSymbolName: "\(status.symbolName).fill", accessibilityDescription: nil) != nil)
        }
    }
}

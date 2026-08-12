import Testing
@testable import AbyssCore

@Test func activationAndConfigurationReachEnabled() throws {
    var machine = LifecycleStateMachine()
    #expect(try machine.apply(.requestActivation) == .activating)
    #expect(try machine.apply(.approvalRequired) == .awaitingApproval)
    #expect(try machine.apply(.activationSucceeded) == .active)
    #expect(try machine.apply(.beginConfiguration) == .savingFilterConfiguration)
    #expect(try machine.apply(.configurationSaved(enabled: true)) == .enabled)
    #expect(machine.state.telemetryAvailable)
}

@Test func staleConfigurationGetsOneExplicitReloadState() throws {
    var machine = LifecycleStateMachine(state: .active)
    _ = try machine.apply(.beginConfiguration)
    #expect(try machine.apply(.configurationStale) == .stale)
    #expect(try machine.apply(.beginConfiguration) == .savingFilterConfiguration)
}

@Test func invalidTransitionIsRejectedWithoutMutation() {
    var machine = LifecycleStateMachine()
    #expect(throws: LifecycleTransitionError.self) {
        try machine.apply(.configurationSaved(enabled: true))
    }
    #expect(machine.state == .notInstalled)
}

@Test func uninstallReturnsToNotInstalled() throws {
    var machine = LifecycleStateMachine(state: .enabled)
    #expect(try machine.apply(.beginUninstall) == .uninstalling)
    #expect(try machine.apply(.uninstallSucceeded) == .notInstalled)
}

@Test func degradedStatesNeverClaimTelemetry() {
    let states: [LifecycleState] = [
        .denied(message: "redacted"), .disabled, .stale,
        .failed(message: "redacted"),
    ]
    #expect(states.allSatisfy { $0.isDegraded })
    #expect(states.allSatisfy { !$0.telemetryAvailable })
}

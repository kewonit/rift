import Testing
@testable import RiftControl

@Test func lockingStopsChangesByHandButNotAutomaticOnes() {
    var state = ConfigurationLockState(launchingWithLockEnabled: false)
    #expect(!state.isLocked)
    #expect(state.permits(.byHand))
    state.lock()
    #expect(state.isLocked)
    #expect(!state.permits(.byHand))
    // Subscription updates and switching profiles by network carry on.
    #expect(state.permits(.automatic))
}

@Test func unlockUntilQuitLocksAgainOnTheNextLaunch() {
    var state = ConfigurationLockState(launchingWithLockEnabled: true)
    #expect(state.isLocked)
    state.unlock(untilQuit: true)
    #expect(!state.isLocked)
    #expect(state.isEnabled)
    let nextLaunch = ConfigurationLockState(launchingWithLockEnabled: state.isEnabled)
    #expect(nextLaunch.isLocked)

    state.lock()
    state.unlock(untilQuit: false)
    #expect(!state.isEnabled)
    #expect(!ConfigurationLockState(launchingWithLockEnabled: state.isEnabled).isLocked)
}

@Test func lockingAgainEndsAnUnlockUntilQuit() {
    var state = ConfigurationLockState(launchingWithLockEnabled: true)
    state.unlock(untilQuit: true)
    state.lock()
    #expect(state.isLocked)
    // Unlock Until Quit with nothing locked leaves nothing to undo later.
    var open = ConfigurationLockState(launchingWithLockEnabled: false)
    open.unlock(untilQuit: true)
    open.lock()
    #expect(open.isLocked)
}

@Test func aLockedAlertCanOnlyBeAnsweredOnce() {
    #expect(!ConnectionAlertPresentation.allowsLastingChoice(
        canCreateRule: true, needsSystemConfirmation: false, systemConfirmed: false, configurationLocked: true
    ))
    #expect(ConnectionAlertPresentation.allowsLastingChoice(
        canCreateRule: true, needsSystemConfirmation: false, systemConfirmed: false, configurationLocked: false
    ))
    #expect(ConnectionAlertPresentation.lastingChoiceHint(
        hasIdentity: true, hasEndpoint: true, configurationLocked: true
    ) == "Rift’s configuration is locked, so you can only answer once.")
}

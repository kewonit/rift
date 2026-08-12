import Testing
@testable import AbyssControl

@Test func reconnectContinuesBeyondLegacyWindowThenResetsAfterRecovery() throws {
    var state = ControlPlaneReconnectState()
    let began = state.beginIfNeeded()
    #expect(began)

    var elapsedSeconds: UInt64 = 0
    for expected in [1, 2, 4, 8, 16, 30] as [UInt64] {
        let optionalDelay = state.delayAfterFailureSeconds()
        let delay = try #require(optionalDelay)
        #expect(delay == expected)
        elapsedSeconds += delay
    }
    #expect(elapsedSeconds == 61)
    #expect(state.isRunning)
    let cappedDelay = state.delayAfterFailureSeconds()
    #expect(cappedDelay == 30)

    state.finishAndReset()
    #expect(!state.isRunning)
    let restarted = state.beginIfNeeded()
    let resetDelay = state.delayAfterFailureSeconds()
    #expect(restarted)
    #expect(resetDelay == 1)
}

@Test func repeatedReconnectTriggersKeepOneRunningLoop() {
    var state = ControlPlaneReconnectState()
    var loopStarts = 0

    for _ in 0..<100 {
        if state.beginIfNeeded() { loopStarts += 1 }
    }

    #expect(loopStarts == 1)
    #expect(state.isRunning)
    let firstDelay = state.delayAfterFailureSeconds()
    for _ in 0..<100 {
        let duplicateStart = state.beginIfNeeded()
        #expect(!duplicateStart)
    }
    let secondDelay = state.delayAfterFailureSeconds()
    #expect(firstDelay == 1)
    #expect(secondDelay == 2)
    state.finishAndReset()
    let restarted = state.beginIfNeeded()
    #expect(restarted)
}

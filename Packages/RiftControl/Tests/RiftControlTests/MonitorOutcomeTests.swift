import Foundation
import RiftControl
import RiftCore
import RiftIPC
import Testing

private func event(
    _ action: FilterAction,
    _ reason: RuntimeEventReason,
    rule: UUID? = nil
) -> RuntimeEvent {
    RuntimeEvent(
        providerEpoch: UUID(),
        sequence: 1,
        occurredAt: Date(timeIntervalSince1970: 1_000),
        flow: FlowDescriptor(
            flowID: UUID(),
            observedAt: Date(timeIntervalSince1970: 1_000),
            sourceAppIdentity: nil,
            sourceProcessIdentity: nil,
            owner: .user(uid: 501),
            direction: .outgoing,
            transportProtocol: .tcp,
            localEndpoint: nil,
            remoteEndpoint: nil,
            observedHostname: nil,
            metadataConfidence: []
        ),
        action: action,
        reason: reason,
        policy: nil,
        winningRuleID: rule
    )
}

@Test func aModeBlockIsBlocked() {
    let value = event(.deny, .unmatchedModeFallback)
    #expect(value.outcome == .blocked)
    #expect(value.cause == .mode)
    #expect(value.tally == .blocked)
    #expect(value.causeSentence == "No rule decided this, so your mode blocked it.")
}

@Test func aRuleBlockIsBlocked() {
    let value = event(.deny, .concreteDecision, rule: UUID())
    #expect(value.tally == .blocked)
    #expect(value.cause == .rule)
}

@Test func anAnswerWithNoRuleIsNotCalledARule() {
    let value = event(.deny, .concreteDecision)
    #expect(value.cause == .yourAnswer)
    #expect(value.causeSentence == "You blocked it when Rift asked.")
}

@Test func aTimedOutAlertIsAllowedWithNoRule() {
    let value = event(.allow, .promptDeadlineFallback)
    #expect(value.outcome == .allowed)
    #expect(value.cause == .alertTimedOut)
    #expect(value.tally == .noRule)
}

@Test func anAllowFromTheModeCountsAsNoRule() {
    let value = event(.allow, .unmatchedModeFallback)
    #expect(value.tally == .noRule)
    #expect(value.causeSentence == "No rule decided this, so your mode allowed it.")
}

@Test func anAskActionIsTreatedAsAllowed() {
    #expect(event(.ask, .noActivePolicy).outcome == .allowed)
}

private func row(_ action: FilterAction, _ reason: RuntimeEventReason) -> MonitorEventRow {
    MonitorEventRow(event: event(action, reason), coverage: .complete)
}

@Test func aModeBlockAppearsUnderBlockedAndUnderNoRule() {
    let rows = [row(.deny, .unmatchedModeFallback)]
    #expect(MonitorQuery.filter(rows, search: "", lens: .application, decision: .denied).count == 1)
    #expect(MonitorQuery.filter(rows, search: "", lens: .application, decision: .unresolved).count == 1)
    #expect(MonitorQuery.filter(rows, search: "", lens: .application, decision: .allowed).isEmpty)
}

@Test func anAllowWithNoRuleAppearsUnderAllowedAndUnderNoRule() {
    let rows = [row(.allow, .unmatchedModeFallback)]
    #expect(MonitorQuery.filter(rows, search: "", lens: .application, decision: .allowed).count == 1)
    #expect(MonitorQuery.filter(rows, search: "", lens: .application, decision: .unresolved).count == 1)
    #expect(MonitorQuery.filter(rows, search: "", lens: .application, decision: .denied).isEmpty)
}

@Test func searchFindsTheWordsPeopleSee() {
    let blocked = [row(.deny, .unmatchedModeFallback)]
    for term in ["blocked", "denied", "\"by default\"", "\"no rule\"", "decision:blocked"] {
        #expect(MonitorQuery.filter(blocked, search: term, lens: .application).count == 1)
    }
    let timedOut = [row(.allow, .promptDeadlineFallback)]
    #expect(MonitorQuery.filter(timedOut, search: "\"timed out\"", lens: .application).count == 1)
    #expect(MonitorQuery.filter(timedOut, search: "blocked", lens: .application).isEmpty)
}

@Test func summaryAndGroupCountsIncludeEveryBlock() {
    let rows = [
        row(.deny, .unmatchedModeFallback),
        row(.deny, .concreteDecision),
        row(.allow, .concreteDecision),
        row(.allow, .promptDeadlineFallback),
    ]
    let summary = MonitorSummaryBuilder.build(
        from: MonitorQuery.filter(rows, search: "", lens: .application)
    )
    #expect(summary.denied == 2)
    #expect(summary.allowed == 1)
    #expect(summary.unresolved == 1)
    #expect(summary.denied + summary.allowed + summary.unresolved == rows.count)
}

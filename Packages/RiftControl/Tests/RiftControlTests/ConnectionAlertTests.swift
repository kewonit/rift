import Foundation
import RiftControl
import RiftCore
import RiftIPC
import Testing

private func prompt(
    nonce: UUID = UUID(),
    epoch: UUID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
    flow: UUID = UUID(),
    deadline: TimeInterval = 100
) -> PromptRequest {
    PromptRequest(
        nonce: nonce, providerEpoch: epoch, lineageID: UUID(), generation: 1, flowID: flow,
        observedAt: Date(timeIntervalSince1970: 0),
        deadline: Date(timeIntervalSince1970: deadline),
        owner: .user(uid: 501), appIdentity: nil, processIdentity: nil, direction: .outgoing,
        transportProtocol: .tcp, endpoint: nil, winningRuleID: nil, affectingRuleIDs: []
    )
}

private let now = Date(timeIntervalSince1970: 10)

@Test func anUpdatedPromptKeepsItsPlaceInTheQueue() {
    let first = prompt(), second = prompt()
    let updated = prompt(nonce: first.nonce, deadline: 200)
    let result = PromptListMerge.merged(existing: [first, second], incoming: [updated], now: now)
    #expect(result.map(\.nonce) == [first.nonce, second.nonce])
    #expect(result.first?.deadline == updated.deadline)
}

@Test func theSameFlowWithANewNonceReplacesTheOldPrompt() {
    let flow = UUID()
    let first = prompt(flow: flow), other = prompt()
    let renewed = prompt(flow: flow)
    let result = PromptListMerge.merged(existing: [first, other], incoming: [renewed], now: now)
    #expect(result.map(\.nonce) == [renewed.nonce, other.nonce])
}

@Test func newPromptsJoinTheEndOfTheQueue() {
    let first = prompt(), second = prompt()
    let result = PromptListMerge.merged(existing: [first], incoming: [second], now: now)
    #expect(result.map(\.nonce) == [first.nonce, second.nonce])
}

@Test func expiredPromptsLeaveTheQueueAndNeverJoinIt() {
    let expired = prompt(deadline: 5), live = prompt()
    let late = prompt(deadline: 1)
    let result = PromptListMerge.merged(existing: [expired, live], incoming: [late], now: now)
    #expect(result.map(\.nonce) == [live.nonce])
}

@Test func duplicatesOfAnUpdatedPromptCollapseIntoOne() {
    let flow = UUID()
    let older = prompt(flow: flow), newer = prompt(flow: flow), other = prompt()
    let update = prompt(nonce: newer.nonce, flow: flow)
    let result = PromptListMerge.merged(existing: [older, other, newer], incoming: [update], now: now)
    #expect(result.map(\.nonce) == [update.nonce, other.nonce])
}

@Test func outgoingAlertsNameTheDestination() {
    let text = ConnectionAlertPresentation.headline(
        application: "Safari", destination: "example.test:443", direction: .outgoing
    )
    #expect(text == "Safari wants to connect to example.test:443.")
}

@Test func incomingAlertsNeverNameARemoteHost() {
    let text = ConnectionAlertPresentation.headline(
        application: "Music", destination: "192.0.2.1:443", direction: .incoming
    )
    #expect(text == "Something wants to connect to Music on this Mac.")
    #expect(!text.contains("192.0.2.1"))
}

@Test func aSystemProcessNeedsConfirmationBeforeALastingChoice() {
    #expect(!ConnectionAlertPresentation.allowsLastingChoice(
        canCreateRule: true, needsSystemConfirmation: true, systemConfirmed: false
    ))
    #expect(ConnectionAlertPresentation.allowsLastingChoice(
        canCreateRule: true, needsSystemConfirmation: true, systemConfirmed: true
    ))
    #expect(ConnectionAlertPresentation.allowsLastingChoice(
        canCreateRule: true, needsSystemConfirmation: false, systemConfirmed: false
    ))
    #expect(!ConnectionAlertPresentation.allowsLastingChoice(
        canCreateRule: false, needsSystemConfirmation: false, systemConfirmed: false
    ))
}

@Test func aDisabledLastingChoiceExplainsWhy() {
    #expect(ConnectionAlertPresentation.lastingChoiceHint(hasIdentity: false, hasEndpoint: true) != nil)
    #expect(ConnectionAlertPresentation.lastingChoiceHint(hasIdentity: true, hasEndpoint: false) != nil)
    #expect(ConnectionAlertPresentation.lastingChoiceHint(hasIdentity: true, hasEndpoint: true) == nil)
}

@Test func theWaitingCountOnlyAppearsWhenThereAreMore() {
    #expect(ConnectionAlertPresentation.moreWaitingLabel(0) == nil)
    #expect(ConnectionAlertPresentation.moreWaitingLabel(2) == "2 more waiting")
}

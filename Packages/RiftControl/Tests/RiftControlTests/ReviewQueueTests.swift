import Foundation
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

private let epoch = UUID()

private func app(_ name: String) -> ProcessIdentity {
    .developerID(try! SignedCodeIdentity(teamIdentifier: "TEAM", signingIdentifier: "com.example.\(name)"))
}

private func row(
    _ identity: ProcessIdentity,
    host: String,
    at seconds: TimeInterval,
    reason: RuntimeEventReason = .unmatchedModeFallback,
    action: FilterAction = .allow
) throws -> MonitorEventRow {
    let flow = FlowDescriptor(
        flowID: UUID(), observedAt: Date(timeIntervalSince1970: seconds), sourceAppIdentity: identity,
        sourceProcessIdentity: identity, owner: .user(uid: 501), direction: .outgoing,
        transportProtocol: .tcp, localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("198.51.100.8"), port: 443, hostname: try DomainName(host),
            hostnameCoverage: .observed, classes: [], interfaceSnapshotGeneration: 0
        ),
        observedHostname: nil, metadataConfidence: [.endpoint]
    )
    let event = RuntimeEvent(
        providerEpoch: epoch, sequence: UInt64.random(in: 1...UInt64.max), occurredAt: Date(timeIntervalSince1970: seconds),
        flow: flow, action: action, reason: reason, policy: nil
    )
    return MonitorEventRow(event: event, coverage: .complete)
}

private func undecided(_ rows: [MonitorEventRow]) -> Set<String> {
    Set(ReviewQueue.candidates(in: rows).map(\.id))
}

@Test func appsWithNoRuleAreGroupedNewestFirst() throws {
    let rows = [
        try row(app("mail"), host: "imap.example.test", at: 100),
        try row(app("mail"), host: "imap.example.test", at: 300),
        try row(app("mail"), host: "smtp.example.test", at: 200),
        try row(app("news"), host: "feeds.example.test", at: 400),
        // Decided by a rule, so there is nothing to review.
        try row(app("chat"), host: "chat.example.test", at: 500, reason: .concreteDecision),
    ]
    let queue = ReviewQueue.build(rows: rows, stillUndecided: undecided(rows), dismissed: [:])
    #expect(queue.apps.map(\.identity) == [app("news"), app("mail")])
    let mail = try #require(queue.apps.last)
    #expect(mail.destinations.map(\.host) == ["imap.example.test", "smtp.example.test"])
    #expect(mail.destinations.first?.count == 2)
    #expect(mail.destinations.first?.firstSeen == Date(timeIntervalSince1970: 100))
    #expect(queue.unanswered.isEmpty)
}

@Test func aDestinationARuleNowCoversLeavesTheQueue() throws {
    let rows = [
        try row(app("mail"), host: "imap.example.test", at: 100),
        try row(app("mail"), host: "smtp.example.test", at: 200),
    ]
    let covered = ReviewQueue.candidates(in: rows).first { ReviewQueue.destinationLabel($0) == "smtp.example.test" }
    let stillUndecided = undecided(rows).subtracting([try #require(covered).id])
    let queue = ReviewQueue.build(rows: rows, stillUndecided: stillUndecided, dismissed: [:])
    #expect(queue.apps.first?.destinations.map(\.host) == ["imap.example.test"])
    let none = ReviewQueue.build(rows: rows, stillUndecided: [], dismissed: [:])
    #expect(none.isEmpty)
}

@Test func notNowHidesAnAppUntilItContactsSomewhereNew() throws {
    let earlier = [try row(app("mail"), host: "imap.example.test", at: 100)]
    let key = ReviewQueue.key(for: app("mail"))
    let dismissed = [key: Date(timeIntervalSince1970: 150)]
    #expect(ReviewQueue.build(rows: earlier, stillUndecided: undecided(earlier), dismissed: dismissed).isEmpty)
    // The same destination again doesn't bring it back.
    let again = earlier + [try row(app("mail"), host: "imap.example.test", at: 200)]
    #expect(ReviewQueue.build(rows: again, stillUndecided: undecided(again), dismissed: dismissed).isEmpty)
    // A new destination does.
    let new = again + [try row(app("mail"), host: "smtp.example.test", at: 300)]
    let queue = ReviewQueue.build(rows: new, stillUndecided: undecided(new), dismissed: dismissed)
    #expect(queue.apps.map(\.id) == [key])
}

@Test func unansweredAlertsAreListedPerAppAndDestination() throws {
    let rows = [
        try row(app("sync"), host: "sync.example.test", at: 100, reason: .promptDeadlineFallback),
        try row(app("sync"), host: "sync.example.test", at: 200, reason: .promptDeadlineFallback),
        try row(app("sync"), host: "api.example.test", at: 150, reason: .promptUnavailableFallback, action: .deny),
    ]
    let queue = ReviewQueue.build(rows: rows, stillUndecided: undecided(rows), dismissed: [:])
    #expect(queue.apps.isEmpty)
    #expect(queue.unanswered.map(\.host) == ["sync.example.test", "api.example.test"])
    #expect(queue.unanswered.first?.count == 2)
}

@Test func theAppKeyIsStable() {
    #expect(ReviewQueue.key(for: app("mail")) == ReviewQueue.key(for: app("mail")))
    #expect(ReviewQueue.key(for: app("mail")) != ReviewQueue.key(for: app("news")))
}

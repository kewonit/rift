import Foundation
import GRDB
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

private let notes = ProcessIdentity.developerID(
    try! SignedCodeIdentity(teamIdentifier: "TEAM123456", signingIdentifier: "com.example.notes")
)
private let mail = ProcessIdentity.developerID(
    try! SignedCodeIdentity(teamIdentifier: "TEAM123456", signingIdentifier: "com.example.mail")
)

private func flow(_ app: ProcessIdentity, host: String) throws -> FlowDescriptor {
    FlowDescriptor(
        flowID: UUID(), observedAt: Date(), sourceAppIdentity: app,
        sourceProcessIdentity: app, owner: .user(uid: 501), direction: .outgoing,
        transportProtocol: .tcp, localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("198.51.100.8"), port: 443, hostname: try DomainName(host),
            hostnameCoverage: .observed, classes: [], interfaceSnapshotGeneration: 0
        ),
        observedHostname: nil, metadataConfidence: [.endpoint, .appIdentity]
    )
}

private func repository(
    with flows: [FlowDescriptor], at time: Date
) async throws -> (HistoryRepository, DatabasePool, URL) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let database = try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
    let repository = HistoryRepository(database: database)
    let epoch = UUID()
    let events = flows.enumerated().map { index, flow in
        RuntimeEvent(
            providerEpoch: epoch, sequence: UInt64(index + 1), occurredAt: time, flow: flow,
            action: .allow, reason: .concreteDecision, policy: nil
        )
    }
    try await repository.ingest(RuntimeEventBatch(providerEpoch: epoch, events: events, droppedCount: 0), now: time)
    return (repository, database, directory)
}

@Test func anAlertCanTellAnAppsFirstConnectionToADomain() async throws {
    let start = Date()
    let (history, _, directory) = try await repository(
        with: [try flow(notes, host: "sync.example.com"), try flow(notes, host: "axb.test")],
        at: start.addingTimeInterval(60)
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let later = start.addingTimeInterval(2 * 86_400)
    #expect(try await history.isFirstContact(app: notes, domain: "example.com", before: later) == false)
    #expect(try await history.isFirstContact(app: notes, domain: "sync.example.com", before: later) == false)
    #expect(try await history.isFirstContact(app: mail, domain: "example.com", before: later) == true)
    #expect(try await history.isFirstContact(app: notes, domain: "other.test", before: later) == true)
    // A name with an underscore isn't a pattern.
    #expect(try await history.isFirstContact(app: notes, domain: "a_b.test", before: later) == true)
}

@Test func onlyConnectionsBeforeTheOneAskedAboutCount() async throws {
    let start = Date()
    let (history, _, directory) = try await repository(
        with: [try flow(mail, host: "mail.example.org")], at: start.addingTimeInterval(-3 * 86_400)
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    let epoch = UUID()
    try await history.ingest(RuntimeEventBatch(providerEpoch: epoch, events: [RuntimeEvent(
        providerEpoch: epoch, sequence: 1, occurredAt: start, flow: try flow(notes, host: "sync.example.com"),
        action: .allow, reason: .concreteDecision, policy: nil
    )], droppedCount: 0), now: start)
    let dayBefore = start.addingTimeInterval(-86_400)
    #expect(try await history.isFirstContact(app: notes, domain: "example.com", before: dayBefore) == true)
    #expect(try await history.isFirstContact(app: notes, domain: "example.com", before: start + 60) == false)
}

@Test func historyYoungerThanADayOrTurnedOffCantSay() async throws {
    let start = Date()
    let (history, _, directory) = try await repository(
        with: [try flow(notes, host: "sync.example.com")], at: start
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    #expect(try await history.isFirstContact(app: mail, domain: "example.com", before: start.addingTimeInterval(3_600)) == nil)
    try await history.configure(enabled: false, retentionDays: 30, maximumFlows: 50_000, now: start)
    #expect(try await history.isFirstContact(
        app: mail, domain: "example.com", before: start.addingTimeInterval(2 * 86_400)
    ) == nil)
}

@Test func connectionsSavedBeforeTheIndexAreFilledIn() async throws {
    let start = Date()
    let (history, database, directory) = try await repository(
        with: [try flow(notes, host: "sync.example.com")], at: start.addingTimeInterval(60)
    )
    defer { try? FileManager.default.removeItem(at: directory) }
    try await database.write { database in
        try database.execute(sql: "UPDATE flow_lifecycle SET app_key = NULL, destination_name = NULL")
    }
    let later = start.addingTimeInterval(2 * 86_400)
    #expect(try await history.isFirstContact(app: notes, domain: "example.com", before: later) == true)
    try await database.write { try HistoryContactIndex.backfill(in: $0) }
    #expect(try await history.isFirstContact(app: notes, domain: "example.com", before: later) == false)
}

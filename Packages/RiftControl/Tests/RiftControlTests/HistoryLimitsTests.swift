import Foundation
import GRDB
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

@Test func historyCanBeKeptForAYearAndTwoHundredThousandConnections() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = HistoryRepository(database: try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite")))
    // A new history keeps today's defaults.
    let initial = try await repository.settings()
    #expect(initial.retentionDays == HistoryLimits.defaultRetentionDays)
    #expect(initial.maximumFlows == HistoryLimits.defaultMaximumFlows)

    try await repository.configure(enabled: true, retentionDays: 365, maximumFlows: 200_000)
    var settings = try await repository.settings()
    #expect(settings.retentionDays == 365)
    #expect(settings.maximumFlows == 200_000)

    try await repository.configure(enabled: true, retentionDays: 1_000, maximumFlows: 5_000_000)
    settings = try await repository.settings()
    #expect(settings.retentionDays == 365)
    #expect(settings.maximumFlows == 200_000)
}

@Test func settingsOffersTheLimitsAndKeepsAnUnlistedValue() {
    #expect(HistoryLimits.dayChoices(including: 30).last == 365)
    #expect(HistoryLimits.dayChoices(including: 45).contains(45))
    #expect(!HistoryLimits.dayChoices(including: 900).contains(900))
    #expect(HistoryLimits.flowChoices(including: 50_000).last == 200_000)
    #expect(HistoryLimits.flowChoices(including: 42_000) == HistoryLimits.flowChoices(including: 42_000).sorted())
    #expect(HistoryLimits.daysLabel(365) == "1 year")
    #expect(HistoryLimits.daysLabel(90) == "90 days")
}

@Test func anExportIncludesMoreThanTheMapLoads() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
    let repository = HistoryRepository(database: database)
    try await repository.configure(enabled: true, retentionDays: 365, maximumFlows: 200_000)
    let epoch = UUID()
    let start = Date().addingTimeInterval(-86_400)
    let count = HistoryLimits.maximumLoadedFlows + 25
    let endpoint = Endpoint(
        address: try IPAddress("198.51.100.8"), port: 443, hostname: nil,
        hostnameCoverage: .absent, classes: [], interfaceSnapshotGeneration: 0
    )
    let encoder = CanonicalPolicyJSON.encoder()
    try await database.write { database in
        for index in 0..<count {
            let occurredAt = start.addingTimeInterval(Double(index))
            let flow = FlowDescriptor(
                flowID: UUID(), observedAt: occurredAt, sourceAppIdentity: nil, sourceProcessIdentity: nil,
                owner: .user(uid: 501), direction: .outgoing, transportProtocol: .tcp, localEndpoint: nil,
                remoteEndpoint: endpoint, observedHostname: nil, metadataConfidence: [.endpoint]
            )
            let event = RuntimeEvent(
                providerEpoch: epoch, sequence: UInt64(index + 1), occurredAt: occurredAt, flow: flow,
                action: .allow, reason: .concreteDecision, policy: nil
            )
            try database.execute(
                sql: """
                    INSERT INTO flow_lifecycle
                        (provider_epoch, flow_id, decision_sequence, decision_at, decision_event)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    epoch.uuidString.lowercased(), flow.flowID.uuidString.lowercased(),
                    Int64(index + 1), occurredAt.timeIntervalSince1970, try encoder.encode(event),
                ]
            )
        }
    }
    // The Map still loads a bounded snapshot.
    let snapshot = try await repository.monitorSnapshot(maximum: 1_000_000)
    #expect(snapshot.rows.count == HistoryLimits.maximumLoadedFlows)
    #expect(!snapshot.isComplete)

    let csv = try await repository.exportData(format: .csv, now: Date())
    let lines = csv.split(separator: UInt8(ascii: "\n"))
    #expect(lines.count == count + 1)
    // Newest first, as before.
    #expect(String(decoding: lines[1], as: UTF8.self).contains(String(Int64(((start.timeIntervalSince1970 + Double(count - 1)) * 1_000).rounded()))))
}

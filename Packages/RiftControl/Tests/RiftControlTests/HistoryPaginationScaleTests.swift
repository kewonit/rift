import RiftCore
import RiftIPC
import Foundation
import GRDB
import Testing
@testable import RiftControl

@Test func historyPagesFirstAndLastWindowsAtFiftyThousandRows() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
    let repository = HistoryRepository(database: database)
    let epoch = UUID()
    let startDate = Date(timeIntervalSince1970: 1_800_000_000)
    let endpoint = Endpoint(
        address: try IPAddress("198.51.100.8"),
        port: 443,
        hostname: nil,
        hostnameCoverage: .absent,
        classes: [],
        interfaceSnapshotGeneration: 0
    )
    let encoder = CanonicalPolicyJSON.encoder()

    try await database.write { database in
        for index in 0..<50_000 {
            let occurredAt = startDate.addingTimeInterval(Double(index))
            let flow = FlowDescriptor(
                flowID: UUID(),
                observedAt: occurredAt,
                sourceAppIdentity: nil,
                sourceProcessIdentity: nil,
                owner: .user(uid: 501),
                direction: .outgoing,
                transportProtocol: .tcp,
                localEndpoint: nil,
                remoteEndpoint: endpoint,
                observedHostname: nil,
                metadataConfidence: [.endpoint]
            )
            let event = RuntimeEvent(
                providerEpoch: epoch,
                sequence: UInt64(index + 1),
                occurredAt: occurredAt,
                flow: flow,
                action: index.isMultiple(of: 7) ? .deny : .allow,
                reason: .concreteDecision,
                policy: nil
            )
            try database.execute(
                sql: """
                    INSERT INTO flow_lifecycle
                        (provider_epoch, flow_id, decision_sequence, decision_at, decision_event)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    epoch.uuidString.lowercased(),
                    flow.flowID.uuidString.lowercased(),
                    Int64(index + 1),
                    occurredAt.timeIntervalSince1970,
                    try encoder.encode(event),
                ]
            )
        }
    }

    let clock = ContinuousClock()
    let newestStart = clock.now
    let newest = try await repository.page(limit: 1_000, offset: 0)
    let newestDuration = newestStart.duration(to: clock.now)
    let oldestStart = clock.now
    let oldest = try await repository.page(limit: 1_000, offset: 49_000)
    let oldestDuration = oldestStart.duration(to: clock.now)

    #expect(newest.count == 1_000)
    #expect(oldest.count == 1_000)
    #expect(newest.first?.event.sequence == 50_000)
    #expect(oldest.last?.event.sequence == 1)
    #expect(Set(newest.map(\.id)).count == newest.count)
    #expect(Set(oldest.map(\.id)).count == oldest.count)
    #expect(newestDuration < .seconds(2))
    #expect(oldestDuration < .seconds(2))
    print(
        "HISTORY_PAGINATION_BENCHMARK rows=50000 first_1000=\(newestDuration) "
            + "last_1000=\(oldestDuration)"
    )
}

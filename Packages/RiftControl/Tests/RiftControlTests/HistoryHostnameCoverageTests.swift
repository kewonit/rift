import Foundation
import RiftCore
import RiftIPC
import Testing
@testable import RiftControl

private func flow(hostname: String?, direction: TrafficDirection = .outgoing) throws -> FlowDescriptor {
    FlowDescriptor(
        flowID: UUID(), observedAt: Date(), sourceAppIdentity: nil,
        sourceProcessIdentity: nil, owner: .user(uid: 501), direction: direction,
        transportProtocol: .tcp, localEndpoint: nil,
        remoteEndpoint: Endpoint(
            address: try IPAddress("198.51.100.8"), port: 443,
            hostname: try hostname.map(DomainName.init),
            hostnameCoverage: hostname == nil ? .absent : .observed,
            classes: [], interfaceSnapshotGeneration: 0
        ),
        observedHostname: nil, metadataConfidence: [.endpoint]
    )
}

@Test func hostnameCoverageCountsOutgoingConnectionsWithoutAName() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repository = HistoryRepository(
        database: try HistoryDatabase.open(at: directory.appendingPathComponent("history.sqlite"))
    )
    let epoch = UUID()
    let flows = [
        try flow(hostname: "example.test"),
        try flow(hostname: nil),
        try flow(hostname: nil),
        try flow(hostname: "cdn.example.test"),
        // Incoming connections have no remote name to miss.
        try flow(hostname: nil, direction: .incoming),
    ]
    let events = flows.enumerated().map { index, flow in
        RuntimeEvent(
            providerEpoch: epoch, sequence: UInt64(index + 1), occurredAt: Date(), flow: flow,
            action: .allow, reason: .concreteDecision, policy: nil
        )
    }
    try await repository.ingest(RuntimeEventBatch(providerEpoch: epoch, events: events, droppedCount: 0), now: Date())

    let coverage = try await repository.hostnameCoverage(since: Date().addingTimeInterval(-3_600))
    #expect(coverage == HistoryHostnameCoverage(outgoing: 4, withoutHostname: 2))
    #expect(coverage.shareWithoutHostname == 0.5)
    let later = try await repository.hostnameCoverage(since: Date().addingTimeInterval(3_600))
    #expect(later.outgoing == 0)
    #expect(later.shareWithoutHostname == nil)
}

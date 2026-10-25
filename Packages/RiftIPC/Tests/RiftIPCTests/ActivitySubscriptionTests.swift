import Foundation
import Testing
@testable import RiftIPC

@Test func activitySubscriptionRequiresIPC12AndValidatedBounds() throws {
    #expect(!ProtocolVersion.baseline.supports(minimum: .activitySubscriptions))
    #expect(!ProtocolVersion.configurationReset.supports(minimum: .activitySubscriptions))
    #expect(ProtocolVersion.current.supports(minimum: .activitySubscriptions))
    #expect(ActivitySubscription(mode: .off).isValid)
    #expect(ActivitySubscription(mode: .persistent).isValid)
    for limit in [1, 5, 50] {
        let subscription = ActivitySubscription(mode: .recent, maximumRecentConnections: limit)
        #expect(subscription.isValid)
        #expect(try SecureIPCCodec.decode(ActivitySubscription.self,
            from: SecureIPCCodec.encode(subscription)) == subscription)
    }
    #expect(!ActivitySubscription(mode: .recent).isValid)
    #expect(!ActivitySubscription(mode: .recent, maximumRecentConnections: 51).isValid)
    #expect(!ActivitySubscription(mode: .off, maximumRecentConnections: 5).isValid)
}

@Test func emptyRecentSnapshotAndAttentionRoundTripWithoutHistory() throws {
    let snapshot = RecentActivitySnapshot(subscriptionID: UUID(), providerEpoch: UUID(),
        revision: 7, events: [], isTruncated: true, nextExpiry: nil)
    #expect(try SecureIPCCodec.decode(RecentActivitySnapshot.self,
        from: SecureIPCCodec.encode(snapshot)) == snapshot)
    let attention = RuntimeAttentionBatch(providerEpoch: snapshot.providerEpoch, prompts: [],
        activePromptNonces: [UUID()], notifications: [], recentDenyAt: Date(timeIntervalSince1970: 10_000))
    #expect(try SecureIPCCodec.decode(RuntimeAttentionBatch.self,
        from: SecureIPCCodec.encode(attention)) == attention)
}

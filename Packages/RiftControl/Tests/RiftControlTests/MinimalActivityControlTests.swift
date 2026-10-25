import Foundation
import RiftIPC
import Testing
@testable import RiftControl

@Test(arguments: [5, 10, 50]) func minimalTransientActivityKeepsOnlyNewestFlows(capacity: Int) {
    let context = LightweightEvents()
    var buffer = TransientHistoryBuffer(maximumFlows: capacity)
    let decisions = (0..<500).map { index in
        let date = context.now.addingTimeInterval(Double(index))
        return context.event(sequence: UInt64(index * 2 + 1), flow: context.flow(at: date), at: date)
    }
    for decision in decisions {
        let closed = context.event(sequence: decision.sequence + 1, flow: decision.flow,
                                   kind: .closed, bytes: 42, at: decision.occurredAt.addingTimeInterval(0.5))
        buffer.ingest(RuntimeEventBatch(providerEpoch: context.epoch, events: [closed, decision], droppedCount: 0))
    }
    let rows = buffer.page(limit: 1_000)
    #expect(rows.count == capacity)
    #expect(Set(rows.map(\.event.flow.flowID)) == Set(decisions.suffix(capacity).map(\.flow.flowID)))
    #expect(rows.allSatisfy { $0.closedAt != nil && $0.bytesInbound == 42 })
    #expect(!buffer.hasPendingReplay && buffer.replaySnapshot().batches.isEmpty)
    buffer.clearDisplay()
    #expect(buffer.page().isEmpty)
}

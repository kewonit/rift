import RiftControl
import Foundation

/// Sent and received bytes in equal time bins across the visible range.
struct LiveTrafficBin: Sendable, Hashable {
    var sent: UInt64 = 0
    var received: UInt64 = 0
}

struct LiveTrafficSnapshot: Sendable, Hashable {
    let bins: [LiveTrafficBin]
    let sent: UInt64
    let received: UInt64
    let partial: Bool

    static let empty = LiveTrafficSnapshot(
        bins: Array(repeating: LiveTrafficBin(), count: 30),
        sent: 0,
        received: 0,
        partial: true
    )

    var maximum: UInt64 {
        bins.reduce(0) { max($0, max($1.sent, $1.received)) }
    }

    static func make(
        rows: [MonitorEventRow],
        bounds: (start: Date, end: Date)?
    ) -> LiveTrafficSnapshot {
        let count = 30
        var bins = Array(repeating: LiveTrafficBin(), count: count)
        guard let bounds, bounds.start < bounds.end else {
            return LiveTrafficSnapshot(bins: bins, sent: 0, received: 0, partial: true)
        }
        let duration = bounds.end.timeIntervalSince(bounds.start)
        var sent: UInt64 = 0
        var received: UInt64 = 0
        var partial = false
        for row in rows where row.event.occurredAt >= bounds.start && row.event.occurredAt < bounds.end {
            let progress = row.event.occurredAt.timeIntervalSince(bounds.start) / duration
            let index = min(max(Int(progress * Double(count)), 0), count - 1)
            if let value = row.bytesOutbound {
                sent = adding(sent, value)
                bins[index].sent = adding(bins[index].sent, value)
            } else { partial = true }
            if let value = row.bytesInbound {
                received = adding(received, value)
                bins[index].received = adding(bins[index].received, value)
            } else { partial = true }
            if row.coverage != .complete { partial = true }
        }
        return LiveTrafficSnapshot(
            bins: bins, sent: sent, received: received, partial: partial
        )
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}

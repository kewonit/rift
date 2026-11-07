#if DEBUG
import Foundation
import os
import RiftControl

/// Debug-only streaming workload for the `burst` fixture. It adds a rolling
/// window of synthetic connections that changes every second, so profiling and
/// screenshots exercise the same refresh path real traffic does.
enum MonitorFixtureStream {
    static let eventsPerSecond = 4
    static let retainedEvents = 360
    private static let started = Date()
    private static let cache = OSAllocatedUnfairLock<CachedRows>(initialState: CachedRows())

    private struct CachedRows: Sendable {
        var tick = -1
        var rows: [MonitorEventRow] = []
    }

    /// The streaming rows merged with `base`, newest first. Stream rows sit in
    /// the last 90 seconds before the fixture's fixed reference time, so they
    /// fall inside the default 10-minute window.
    static func rows(merging base: [MonitorEventRow], now: Date = Date()) -> [MonitorEventRow] {
        let tick = max(0, Int(now.timeIntervalSince(started) * Double(eventsPerSecond)))
        return cache.withLock { state in
            if state.tick == tick { return state.rows }
            let first = max(0, tick - retainedEvents + 1)
            let streamed = (first...tick).compactMap { index -> MonitorEventRow? in
                let age = Double(tick - index) / Double(eventsPerSecond)
                return try? MonitorFixtureData.makeRow(
                    index: 100_000 + index,
                    addressIndex: index % 240,
                    occurredAt: MonitorFixtureData.referenceNow.addingTimeInterval(-age)
                )
            }
            let merged = (streamed + base).sorted { $0.event.occurredAt > $1.event.occurredAt }
            state = CachedRows(tick: tick, rows: merged)
            return merged
        }
    }

    /// Signals new activity once a second, as the extension does under steady traffic.
    @MainActor
    static func startDriver(_ controller: ControlPlaneController) {
        Task { @MainActor [weak controller] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let controller else { return }
                controller.recordRuntimeActivity(true)
            }
        }
    }
}
#endif

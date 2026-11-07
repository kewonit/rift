import Foundation
import RiftControl
import RiftCore

/// Everything the menu-bar panel shows, computed once per refresh instead of on
/// every view update.
struct StatusMenuSnapshot: Equatable {
    static let window: TimeInterval = 300

    let traffic: LiveTrafficSnapshot
    let applications: [StatusApplicationActivity]
    let deniedCount: Int
    let latestDeniedID: String?

    static let empty = StatusMenuSnapshot(
        traffic: .empty, applications: [], deniedCount: 0, latestDeniedID: nil
    )

    /// `rows` are newest first and already limited to the last five minutes.
    static func make(rows: [MonitorEventRow], now: Date, recentLimit: Int) -> StatusMenuSnapshot {
        let start = now.addingTimeInterval(-window)
        let recentRows = rows.filter { $0.event.occurredAt >= start && $0.event.occurredAt <= now }
        var seen = Set<ProcessIdentity>()
        var seenNames = Set<String>()
        var applications: [StatusApplicationActivity] = []
        var deniedCount = 0
        var latestDeniedID: String?
        for row in recentRows {
            if row.decision == .denied {
                deniedCount += 1
                if latestDeniedID == nil { latestDeniedID = row.id }
            }
            guard applications.count < recentLimit else { continue }
            let identity = row.event.flow.sourceAppIdentity ?? row.event.flow.sourceProcessIdentity
            let name = MonitorQuery.applicationLabel(row)
            let isNew = identity.map { seen.insert($0).inserted } ?? seenNames.insert(name).inserted
            guard isNew else { continue }
            applications.append(StatusApplicationActivity(
                eventID: row.id,
                identity: identity,
                name: name,
                destination: MonitorQuery.endpointLabel(row),
                decision: row.decision,
                occurredAt: row.event.occurredAt
            ))
        }
        return StatusMenuSnapshot(
            traffic: LiveTrafficSnapshot.make(rows: recentRows, bounds: (start, now)),
            applications: applications,
            deniedCount: deniedCount,
            latestDeniedID: latestDeniedID
        )
    }
}

struct StatusApplicationActivity: Identifiable, Equatable {
    struct ID: Hashable {
        let identity: ProcessIdentity?
        let name: String
    }

    /// Stable per app, so rows (and their icons) survive refreshes.
    var id: ID { ID(identity: identity, name: name) }
    let eventID: String
    let identity: ProcessIdentity?
    let name: String
    let destination: String
    let decision: RiftDecision
    let occurredAt: Date
}

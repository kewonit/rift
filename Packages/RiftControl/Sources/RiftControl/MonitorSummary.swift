import Foundation
import RiftCore

/// What the connections in view add up to, for the inspector when nothing is
/// selected.
public struct MonitorSummary: Sendable, Equatable {
    public struct Entry: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let connections: Int
        public let blocked: Int
    }

    public let connections: Int
    public let apps: Int
    public let hostnames: Int
    public let blocked: Int
    /// Connections no rule decided, including alerts that timed out.
    public let undecided: Int
    public let incoming: Int
    public let bytesInbound: UInt64?
    public let bytesOutbound: UInt64?
    public let topApps: [Entry]
    public let topHostnames: [Entry]
    public let topCountries: [Entry]

    public static let empty = MonitorSummary(rows: [], context: .none)

    public static func make(
        _ rows: [MonitorDisplayRow],
        context: MonitorSearchContext,
        limit: Int = 3
    ) -> MonitorSummary {
        MonitorSummary(rows: rows.map(\.source), context: context, limit: limit)
    }

    init(rows: [MonitorEventRow], context: MonitorSearchContext, limit: Int = 3) {
        var apps = Tally()
        var hostnames = Tally()
        var countries = Tally()
        var blocked = 0
        var undecided = 0
        var incoming = 0
        var countryCache: [IPAddress: MonitorCountryGroup] = [:]
        for row in rows {
            let flow = row.event.flow
            let isBlocked = row.event.outcome == .blocked
            if isBlocked { blocked += 1 }
            if row.event.reason != .concreteDecision { undecided += 1 }
            if flow.direction == .incoming { incoming += 1 }
            let identity = flow.sourceAppIdentity ?? flow.sourceProcessIdentity
            apps.add(
                key: String(reflecting: identity),
                title: identity.flatMap { context.displayNames[$0] } ?? MonitorQuery.applicationLabel(row),
                blocked: isBlocked
            )
            if flow.metadataConfidence.contains(.observedHostname), let host = flow.observedHostname {
                hostnames.add(key: host.ascii, title: host.ascii, blocked: isBlocked)
            }
            if let address = flow.remoteEndpoint?.address {
                let group: MonitorCountryGroup
                if let cached = countryCache[address] {
                    group = cached
                } else {
                    group = MonitorCountryGroup(flow, context: context)
                    if countryCache.count < 4_096 { countryCache[address] = group }
                }
                if group.key.hasPrefix("country:") {
                    countries.add(key: group.key, title: group.title, blocked: isBlocked)
                }
            }
        }
        connections = rows.count
        self.apps = apps.count
        self.hostnames = hostnames.count
        self.blocked = blocked
        self.undecided = undecided
        self.incoming = incoming
        bytesInbound = Self.total(rows.map(\.bytesInbound))
        bytesOutbound = Self.total(rows.map(\.bytesOutbound))
        topApps = apps.top(limit)
        topHostnames = hostnames.top(limit)
        topCountries = countries.top(limit)
    }

    private static func total(_ values: [UInt64?]) -> UInt64? {
        guard values.contains(where: { $0 != nil }) else { return nil }
        var sum: UInt64 = 0
        for value in values.compactMap({ $0 }) {
            let (next, overflow) = sum.addingReportingOverflow(value)
            if overflow { return .max }
            sum = next
        }
        return sum
    }

    /// Counts per key, keeping the first title seen.
    private struct Tally {
        private var values: [String: (key: String, title: String, connections: Int, blocked: Int)] = [:]

        var count: Int { values.count }

        mutating func add(key: String, title: String, blocked: Bool) {
            var value = values[key] ?? (key, title, 0, 0)
            value.connections += 1
            if blocked { value.blocked += 1 }
            values[key] = value
        }

        func top(_ limit: Int) -> [Entry] {
            values.values
                .sorted {
                    ($0.connections, $1.title) > ($1.connections, $0.title)
                }
                .prefix(limit)
                .map {
                    Entry(
                        id: $0.key, title: DisplaySanitizer.plainText($0.title),
                        connections: $0.connections, blocked: $0.blocked
                    )
                }
        }
    }
}

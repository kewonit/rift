import AbyssCore
import AbyssIPC
import Foundation

public enum MonitorLens: String, CaseIterable, Sendable, Identifiable {
    case application = "App"
    case hostname = "Hostname"
    case location = "Location"
    public var id: String { rawValue }

    public static func available(
        mapUIAdmitted: Bool,
        geolocationDatabaseAvailable: Bool
    ) -> [MonitorLens] {
        allCases.filter {
            $0 != .location || (mapUIAdmitted && geolocationDatabaseAvailable)
        }
    }
}

public enum MonitorDecisionFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All decisions"
    case allowed = "Allowed"
    case denied = "Denied"
    case unresolved = "Fallback / unresolved"
    public var id: String { rawValue }
}

public enum MonitorDirectionFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All directions"
    case incoming = "Incoming"
    case outgoing = "Outgoing"
    public var id: String { rawValue }
}

public enum MonitorTimeFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All retained"
    case hour = "Hour"
    case day = "Day"
    case week = "Week"
    case month = "Month"
    public var id: String { rawValue }
}

public enum MonitorSort: String, CaseIterable, Sendable, Identifiable {
    case recent = "Most recent"
    case name = "Name"
    case sent = "Most sent"
    case received = "Most received"
    public var id: String { rawValue }

    public static func available(allowsUnverifiedBytePreview: Bool) -> [MonitorSort] {
        allCases.filter {
            allowsUnverifiedBytePreview || ($0 != .sent && $0 != .received)
        }
    }
}

public struct MonitorDisplayRow: Sendable, Hashable, Identifiable {
    public let source: MonitorEventRow
    public let primary: String
    public let secondary: String
    public let geography: GeoResolution
    public var id: String { source.id }

    public init(
        source: MonitorEventRow,
        primary: String,
        secondary: String,
        geography: GeoResolution
    ) {
        self.source = source
        self.primary = primary
        self.secondary = secondary
        self.geography = geography
    }
}

public enum MonitorQuery {
    public static func filter(
        _ rows: [MonitorEventRow],
        search: String,
        lens: MonitorLens,
        decision: MonitorDecisionFilter = .all,
        direction: MonitorDirectionFilter = .all,
        time: MonitorTimeFilter = .all,
        sort: MonitorSort = .recent,
        geography: [String: GeoResolution] = [:],
        now: Date = Date()
    ) -> [MonitorDisplayRow] {
        filter(
            rows, search: search, lens: lens, decision: decision,
            direction: direction, time: time, sort: sort,
            geography: geography, now: now, cancellationCheck: {}
        )
    }

    public static func filterCancellable(
        _ rows: [MonitorEventRow],
        search: String,
        lens: MonitorLens,
        decision: MonitorDecisionFilter = .all,
        direction: MonitorDirectionFilter = .all,
        time: MonitorTimeFilter = .all,
        sort: MonitorSort = .recent,
        geography: [String: GeoResolution] = [:],
        now: Date = Date()
    ) throws -> [MonitorDisplayRow] {
        try filter(
            rows, search: search, lens: lens, decision: decision,
            direction: direction, time: time, sort: sort,
            geography: geography, now: now,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    static func filter(
        _ rows: [MonitorEventRow],
        search: String,
        lens: MonitorLens,
        decision: MonitorDecisionFilter,
        direction: MonitorDirectionFilter,
        time: MonitorTimeFilter,
        sort: MonitorSort,
        geography: [String: GeoResolution],
        now: Date,
        cancellationCheck: () throws -> Void
    ) rethrows -> [MonitorDisplayRow] {
        guard let timeWindow = time.window(now: now) else { return [] }
        return try filter(
            rows,
            search: search,
            lens: lens,
            decision: decision,
            direction: direction,
            timeWindow: timeWindow,
            sort: sort,
            geography: geography,
            cancellationCheck: cancellationCheck
        )
    }

    static func filter(
        _ rows: [MonitorEventRow],
        search: String,
        lens: MonitorLens,
        decision: MonitorDecisionFilter,
        direction: MonitorDirectionFilter,
        timeWindow: MonitorTimeWindow,
        sort: MonitorSort,
        geography: [String: GeoResolution],
        cancellationCheck: () throws -> Void
    ) rethrows -> [MonitorDisplayRow] {
        try cancellationCheck()
        let searchQuery = MonitorSearchQuery(search)
        guard !searchQuery.isRejected else { return [] }
        var values: [MonitorDisplayRow] = []
        values.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 64) { try cancellationCheck() }
            guard timeWindow.contains(row.event.occurredAt),
                  matches(row, decision: decision),
                  matches(row, direction: direction) else { continue }
            let app = applicationLabel(row)
            let endpoint = endpointLabel(row)
            let hostname = hostnameLabel(row)
            let resolution = geography[row.id]
                ?? GeoEndpointClassifier.nonGeographic(row.event.flow.destinationEndpoint)
                ?? .notFound
            guard searchQuery.matches(row, geography: resolution) else { continue }
            let labels: (String, String) = switch lens {
            case .application: (app, endpoint)
            case .hostname: (hostname, app)
            case .location: (resolution.displayName, app)
            }
            values.append(MonitorDisplayRow(
                source: row,
                primary: DisplaySanitizer.plainText(labels.0),
                secondary: DisplaySanitizer.plainText(labels.1),
                geography: resolution
            ))
        }
        try cancellationCheck()
        let sorted = values.sorted { lhs, rhs in
            switch sort {
            case .recent:
                if lhs.source.event.occurredAt != rhs.source.event.occurredAt {
                    return lhs.source.event.occurredAt > rhs.source.event.occurredAt
                }
            case .name:
                let order = lhs.primary.localizedStandardCompare(rhs.primary)
                if order != .orderedSame { return order == .orderedAscending }
            case .sent:
                if bytes(lhs.source.bytesOutbound) != bytes(rhs.source.bytesOutbound) {
                    return bytes(lhs.source.bytesOutbound) > bytes(rhs.source.bytesOutbound)
                }
            case .received:
                if bytes(lhs.source.bytesInbound) != bytes(rhs.source.bytesInbound) {
                    return bytes(lhs.source.bytesInbound) > bytes(rhs.source.bytesInbound)
                }
            }
            return lhs.id < rhs.id
        }
        try cancellationCheck()
        return sorted
    }

    public static func applicationLabel(_ row: MonitorEventRow) -> String {
        identityLabel(row.event.flow.sourceAppIdentity ?? row.event.flow.sourceProcessIdentity)
    }

    public static func endpointLabel(_ row: MonitorEventRow) -> String {
        endpoint(row.event.flow.destinationEndpoint)
    }

    public static func hostnameLabel(_ row: MonitorEventRow) -> String {
        let flow = row.event.flow
        guard flow.metadataConfidence.contains(.observedHostname),
              let hostname = flow.observedHostname else {
            return "Hostname unavailable"
        }
        return hostname.ascii
    }

    public static func protocolLabel(_ row: MonitorEventRow) -> String {
        switch row.event.flow.transportProtocol {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .unsupported(let number): "Protocol \(number)"
        }
    }

    private static func endpoint(_ endpoint: Endpoint?) -> String {
        guard let endpoint else { return "Unknown destination" }
        let host = endpoint.hostname?.ascii ?? endpoint.address.description
        return endpoint.port.map { "\(host):\($0)" } ?? host
    }

    public static func identityLabel(_ identity: ProcessIdentity?) -> String {
        switch identity {
        case .applePlatform(let value), .developerID(let value), .appStore(let value):
            value.signingIdentifier
        case .otherSigner(_, let identifier): identifier
        case .adHoc: "Ad-hoc signed process"
        case .unsigned(let path, _): path
        case nil: "Unknown process"
        }
    }

    private static func matches(
        _ row: MonitorEventRow,
        decision: MonitorDecisionFilter
    ) -> Bool {
        switch decision {
        case .all: true
        case .allowed: row.event.action == .allow && !isUnresolved(row)
        case .denied: row.event.action == .deny && !isUnresolved(row)
        case .unresolved: isUnresolved(row)
        }
    }

    private static func matches(
        _ row: MonitorEventRow,
        direction: MonitorDirectionFilter
    ) -> Bool {
        switch direction {
        case .all: true
        case .incoming: row.event.flow.direction == .incoming
        case .outgoing: row.event.flow.direction == .outgoing
        }
    }

    private static func isUnresolved(_ row: MonitorEventRow) -> Bool {
        row.event.reason != .concreteDecision
    }

    private static func bytes(_ value: UInt64?) -> UInt64 { value ?? 0 }
}

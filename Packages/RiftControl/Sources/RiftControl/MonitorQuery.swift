import RiftCore
import RiftIPC
import Foundation

public enum MonitorLens: String, CaseIterable, Sendable, Identifiable {
    case application = "App"
    case hostname = "Hostname"
    public var id: String { rawValue }
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

public enum MonitorLocalityFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All networks"
    case internet = "Internet"
    case local = "Local network"
    public var id: String { rawValue }
}

public enum MonitorOwnerFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All owners"
    case user = "User processes"
    case system = "System processes"
    case unknown = "Unknown owner"
    public var id: String { rawValue }
}

public enum MonitorTimeFilter: String, CaseIterable, Sendable, Identifiable {
    case twoMinutes = "2 minutes"
    case tenMinutes = "10 minutes"
    case all = "All retained"
    case hour = "Hour"
    case fiveHours = "5 hours"
    case day = "Day"
    case threeDays = "3 days"
    case week = "Week"
    case month = "Month"
    case thirtyDays = "30 days"
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
    public var id: String { source.id }

    public init(
        source: MonitorEventRow,
        primary: String,
        secondary: String
    ) {
        self.source = source
        self.primary = primary
        self.secondary = secondary
    }
}

public enum MonitorQuery {
    public static func filter(
        _ rows: [MonitorEventRow],
        search: String,
        lens: MonitorLens,
        decision: MonitorDecisionFilter = .all,
        direction: MonitorDirectionFilter = .all,
        locality: MonitorLocalityFilter = .all,
        owner: MonitorOwnerFilter = .all,
        time: MonitorTimeFilter = .all,
        sort: MonitorSort = .recent,
        now: Date = Date()
    ) -> [MonitorDisplayRow] {
        filter(
            rows, search: search, lens: lens, decision: decision,
            direction: direction, locality: locality, owner: owner,
            time: time, sort: sort,
            now: now, cancellationCheck: {}
        )
    }

    public static func filterCancellable(
        _ rows: [MonitorEventRow],
        search: String,
        lens: MonitorLens,
        decision: MonitorDecisionFilter = .all,
        direction: MonitorDirectionFilter = .all,
        locality: MonitorLocalityFilter = .all,
        owner: MonitorOwnerFilter = .all,
        time: MonitorTimeFilter = .all,
        sort: MonitorSort = .recent,
        now: Date = Date()
    ) throws -> [MonitorDisplayRow] {
        try filter(
            rows, search: search, lens: lens, decision: decision,
            direction: direction, locality: locality, owner: owner,
            time: time, sort: sort,
            now: now,
            cancellationCheck: { try Task.checkCancellation() }
        )
    }

    static func filter(
        _ rows: [MonitorEventRow],
        search: String,
        lens: MonitorLens,
        decision: MonitorDecisionFilter,
        direction: MonitorDirectionFilter,
        locality: MonitorLocalityFilter,
        owner: MonitorOwnerFilter,
        time: MonitorTimeFilter,
        sort: MonitorSort,
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
            locality: locality,
            owner: owner,
            timeWindow: timeWindow,
            sort: sort,
            cancellationCheck: cancellationCheck
        )
    }

    static func filter(
        _ rows: [MonitorEventRow],
        search: String,
        lens: MonitorLens,
        decision: MonitorDecisionFilter,
        direction: MonitorDirectionFilter,
        locality: MonitorLocalityFilter,
        owner: MonitorOwnerFilter,
        timeWindow: MonitorTimeWindow,
        sort: MonitorSort,
        cancellationCheck: () throws -> Void
    ) rethrows -> [MonitorDisplayRow] {
        try cancellationCheck()
        let searchQuery = MonitorSearchQuery(search)
        guard !searchQuery.isRejected else { return [] }
        var values: [MonitorDisplayRow] = []
        values.reserveCapacity(rows.count)
        var labels: [String: String] = [:]
        var endpointLabels: [Endpoint?: String] = [:]
        for (index, row) in rows.enumerated() {
            if index.isMultiple(of: 64) { try cancellationCheck() }
            guard timeWindow.contains(row.event.occurredAt),
                  matches(row, decision: decision),
                  matches(row, direction: direction),
                  matches(row, locality: locality),
                  matches(row, owner: owner) else { continue }
            guard searchQuery.matches(row) else { continue }
            let rawLabels: (String, String)
            switch lens {
            case .application:
                let endpoint = row.event.flow.destinationEndpoint
                let label = endpointLabels[endpoint] ?? endpointLabel(row)
                if endpointLabels.count < 4_096 { endpointLabels[endpoint] = label }
                rawLabels = (applicationLabel(row), label)
            case .hostname: rawLabels = (hostnameLabel(row), applicationLabel(row))
            }
            values.append(MonitorDisplayRow(
                source: row,
                primary: sanitized(rawLabels.0, cache: &labels),
                secondary: sanitized(rawLabels.1, cache: &labels)
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

    private static func sanitized(_ value: String, cache: inout [String: String]) -> String {
        if let cached = cache[value] { return cached }
        let result = DisplaySanitizer.plainText(value)
        if cache.count < 4_096 { cache[value] = result }
        return result
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

    private static func matches(
        _ row: MonitorEventRow,
        locality: MonitorLocalityFilter
    ) -> Bool {
        guard locality != .all else { return true }
        guard let endpoint = row.event.flow.destinationEndpoint else { return false }
        let localClasses: Set<EndpointClass> = [
            .loopback, .linkLocal, .broadcast, .multicast, .bonjour, .localNetwork,
        ]
        let isLocal = !endpoint.classes.isDisjoint(with: localClasses)
        return locality == .local ? isLocal : !isLocal
    }

    private static func matches(
        _ row: MonitorEventRow,
        owner: MonitorOwnerFilter
    ) -> Bool {
        switch (owner, row.event.flow.owner) {
        case (.all, _), (.user, .user), (.system, .system), (.unknown, .unknown): true
        default: false
        }
    }

    private static func isUnresolved(_ row: MonitorEventRow) -> Bool {
        row.event.reason != .concreteDecision
    }

    private static func bytes(_ value: UInt64?) -> UInt64 { value ?? 0 }
}

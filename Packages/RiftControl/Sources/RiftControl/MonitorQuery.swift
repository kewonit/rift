import RiftCore
import RiftIPC
import Foundation

public enum MonitorLens: String, CaseIterable, Sendable, Identifiable {
    case application = "App"
    case hostname = "Hostname"
    case domain = "Domain"
    case country = "Country"
    public var id: String { rawValue }
}

public enum MonitorDecisionFilter: String, CaseIterable, Sendable, Identifiable {
    case all = "All decisions"
    case allowed = "Allowed"
    case denied = "Blocked"
    case unresolved = "No rule applied"
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
    case user = "Your apps"
    case system = "System services"
    case unknown = "Unknown owner"
    public var id: String { rawValue }
}

public enum MonitorTimeFilter: String, CaseIterable, Sendable, Identifiable {
    case twoMinutes = "2 minutes"
    case tenMinutes = "10 minutes"
    case all = "All history"
    case hour = "This Hour"
    case fiveHours = "5 hours"
    case day = "Today"
    case threeDays = "3 days"
    case week = "This Week"
    case month = "This Month"
    case thirtyDays = "30 days"
    public var id: String { rawValue }

    /// How a live range reads in a sentence. The calendar ranges run from the
    /// start of the period, so they never say "last".
    public var liveLabel: String {
        switch self {
        case .all: String(localized: "All saved activity", bundle: .module)
        case .hour: String(localized: "This hour", bundle: .module)
        case .day: String(localized: "Today", bundle: .module)
        case .week: String(localized: "This week", bundle: .module)
        case .month: String(localized: "This month", bundle: .module)
        case .twoMinutes: String(localized: "Last 2 minutes", bundle: .module)
        case .tenMinutes: String(localized: "Last 10 minutes", bundle: .module)
        case .fiveHours: String(localized: "Last 5 hours", bundle: .module)
        case .threeDays: String(localized: "Last 3 days", bundle: .module)
        case .thirtyDays: String(localized: "Last 30 days", bundle: .module)
        }
    }
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
        country: String? = nil,
        context: MonitorSearchContext = .none,
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
            guard matches(row, country: country, context: context),
                  searchQuery.matches(row, context: context) else { continue }
            let rawLabels: (String, String)
            switch lens {
            case .application:
                let endpoint = row.event.flow.destinationEndpoint
                let label = endpointLabels[endpoint] ?? endpointLabel(row)
                if endpointLabels.count < 4_096 { endpointLabels[endpoint] = label }
                rawLabels = (applicationLabel(row), label)
            case .hostname: rawLabels = (hostnameLabel(row), applicationLabel(row))
            case .domain:
                rawLabels = (MonitorDomainGroup(row.event.flow).title, applicationLabel(row))
            case .country:
                rawLabels = (MonitorCountryGroup(row.event.flow, context: context).title, applicationLabel(row))
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
            return String(localized: "Hostname unavailable", bundle: .module)
        }
        return hostname.ascii
    }

    public static func protocolLabel(_ row: MonitorEventRow) -> String {
        switch row.event.flow.transportProtocol {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .unsupported(let number): String(localized: "Protocol \(String(number))", bundle: .module)
        }
    }

    private static func endpoint(_ endpoint: Endpoint?) -> String {
        guard let endpoint else { return String(localized: "Unknown destination", bundle: .module) }
        let host = endpoint.hostname?.ascii ?? endpoint.address.description
        return endpoint.port.map { "\(host):\($0)" } ?? host
    }

    public static func identityLabel(_ identity: ProcessIdentity?) -> String {
        switch identity {
        case .applePlatform(let value), .developerID(let value), .appStore(let value):
            value.signingIdentifier
        case .otherSigner(_, let identifier): identifier
        case .adHoc: String(localized: "Ad hoc signed app", bundle: .module)
        case .unsigned(let path, _): path
        case nil: String(localized: "Unknown app", bundle: .module)
        }
    }

    private static func matches(
        _ row: MonitorEventRow,
        country: String?,
        context: MonitorSearchContext
    ) -> Bool {
        guard let country else { return true }
        guard let address = row.event.flow.remoteEndpoint?.address else { return false }
        return context.countryCode?(address) == country
    }

    private static func matches(
        _ row: MonitorEventRow,
        decision: MonitorDecisionFilter
    ) -> Bool {
        switch decision {
        case .all: true
        case .allowed: row.event.outcome == .allowed
        case .denied: row.event.outcome == .blocked
        case .unresolved: row.event.reason != .concreteDecision
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
        // An incoming connection is local when the peer is, not this Mac.
        guard let endpoint = row.event.flow.remoteEndpoint else { return false }
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

    private static func bytes(_ value: UInt64?) -> UInt64 { value ?? 0 }
}

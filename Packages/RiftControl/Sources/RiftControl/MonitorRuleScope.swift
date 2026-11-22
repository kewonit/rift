import Foundation
import RiftCore

/// How much a rule made from a connection covers.
///
/// The domain choice is the part someone registered, worked out from the
/// bundled Public Suffix List, so it never covers a suffix like `co.uk`.
public enum MonitorRuleBreadth: String, Sendable, Hashable, CaseIterable, Identifiable {
    case thisHost
    case thisDomain
    case allDestinations
    case exactConnection

    public var id: String { rawValue }
}

public enum MonitorRuleDuration: String, Sendable, Hashable, CaseIterable, Identifiable {
    case fiveMinutes = "Five minutes"
    case oneHour = "One hour"
    case always = "Always"

    public var id: String { rawValue }

    public var interval: TimeInterval? {
        switch self {
        case .always: nil
        case .oneHour: 3_600
        case .fiveMinutes: 300
        }
    }

    /// How long the rule lasts, as the end of a sentence, or nil for always.
    public var phrase: String? {
        switch self {
        case .always: nil
        case .oneHour: "one hour"
        case .fiveMinutes: "five minutes"
        }
    }

    public func expiry(from now: Date) -> Date? {
        interval.map { now.addingTimeInterval($0) }
    }
}

/// Works out what a rule can cover for a set of connections, and describes it.
/// A hostname rule only needs the name, so it covers every port. Incoming
/// connections keep the exact rule, because their destination is this Mac.
public enum MonitorRuleScope {
    /// The choices that make sense for these connections, the exact host first.
    public static func options(
        for rows: [MonitorEventRow],
        suffixes: PublicSuffixList = .shared
    ) -> [MonitorRuleBreadth] {
        let seeds = rows.compactMap(MonitorExactRuleSeed.make)
        guard seeds.count == rows.count, let first = seeds.first,
              seeds.allSatisfy({ $0.process == first.process && $0.owner == first.owner }) else {
            return []
        }
        let single = Set(seeds).count == 1
        guard seeds.allSatisfy({ $0.direction == .outgoing }) else {
            return single ? [.exactConnection] : []
        }
        var options: [MonitorRuleBreadth] = []
        if seeds.allSatisfy({ $0.destination == first.destination }) {
            options.append(.thisHost)
        }
        if let domain = domain(for: rows[0], suffixes: suffixes),
           rows.allSatisfy({ self.domain(for: $0, suffixes: suffixes) == domain }) {
            options.append(.thisDomain)
        }
        options.append(.allDestinations)
        if single { options.append(.exactConnection) }
        return options
    }

    /// The registered domain a connection's name belongs to, like
    /// `example.co.uk` for `www.example.co.uk`, when there's a name and the
    /// suffix list is available.
    public static func domain(
        for row: MonitorEventRow,
        suffixes: PublicSuffixList = .shared
    ) -> DomainName? {
        guard row.event.flow.direction == .outgoing,
              let host = row.event.flow.observedHostname else { return nil }
        return suffixes.registrableDomain(of: host)
    }

    public static func target(
        _ breadth: MonitorRuleBreadth,
        for row: MonitorEventRow,
        suffixes: PublicSuffixList = .shared
    ) throws -> MonitorRuleTarget? {
        guard let seed = MonitorExactRuleSeed.make(from: row) else { return nil }
        let destination: DestinationCondition
        switch breadth {
        case .exactConnection:
            return MonitorRuleTarget(seed: seed)
        case .thisHost:
            destination = seed.destination
        case .thisDomain:
            guard let domain = domain(for: row, suffixes: suffixes) else { return nil }
            destination = try .normalizedDomainSet([domain])
        case .allDestinations:
            destination = .anyEndpoint
        }
        return MonitorRuleTarget(
            process: seed.process, destination: destination, transport: .anySupportedProtocol,
            port: nil, direction: seed.direction, owner: seed.owner
        )
    }

    public static func title(
        _ breadth: MonitorRuleBreadth,
        host: String,
        domain: String? = nil,
        port: UInt16?
    ) -> String {
        switch breadth {
        case .thisHost: "\(host), any port"
        case .thisDomain: "\(domain ?? host) and its subdomains"
        case .allDestinations: "All destinations"
        case .exactConnection: port.map { "Only \(host) on port \($0)" } ?? "Only \(host)"
        }
    }

    /// The destination as it reads in a sentence about the rule.
    /// The scope of a one-click rule from a Map row: the whole app for an
    /// app, the domain for a domain, the name or address for a destination,
    /// and the one connection for a single flow. Countries have none.
    public static func quickBreadth(
        for kind: MonitorHierarchyKind,
        options: [MonitorRuleBreadth]
    ) -> MonitorRuleBreadth? {
        let preferred: [MonitorRuleBreadth] = switch kind {
        case .application, .helper: [.allDestinations]
        case .domain: [.thisDomain]
        case .hostname, .route, .address: [.thisHost, .exactConnection]
        case .flow: [.exactConnection, .thisHost]
        case .country: []
        }
        return preferred.first(where: options.contains)
    }

    public static func phrase(_ breadth: MonitorRuleBreadth, host: String, domain: String? = nil) -> String {
        switch breadth {
        case .thisHost: "\(host) on any port"
        case .thisDomain: "\(domain ?? host) and its subdomains"
        case .allDestinations: "all destinations"
        case .exactConnection: host
        }
    }

    /// Hostname rules need a name from macOS, so say so where it matters.
    public static func limitation(_ breadth: MonitorRuleBreadth, row: MonitorEventRow) -> String? {
        guard breadth == .thisHost || breadth == .thisDomain,
              row.event.flow.observedHostname != nil else { return nil }
        return "This applies to connections that use this name, not direct connections to its IP address."
    }
}

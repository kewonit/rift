import Foundation
import RiftCore

/// How much a rule made from a connection covers.
///
/// There's no subdomain choice on purpose. Without public suffix validation, a
/// host like `co.uk` would cover far more than anyone meant.
public enum MonitorRuleBreadth: String, Sendable, Hashable, CaseIterable, Identifiable {
    case thisHost
    case allDestinations
    case exactConnection

    public var id: String { rawValue }
}

public enum MonitorRuleDuration: String, Sendable, Hashable, CaseIterable, Identifiable {
    case always = "Always"
    case oneHour = "One hour"

    public var id: String { rawValue }

    public func expiry(from now: Date) -> Date? {
        self == .oneHour ? now.addingTimeInterval(3_600) : nil
    }
}

/// Works out what a rule can cover for a set of connections, and describes it.
/// A hostname rule only needs the name, so it covers every port. Incoming
/// connections keep the exact rule, because their destination is this Mac.
public enum MonitorRuleScope {
    /// The choices that make sense for these connections, broadest-useful first.
    public static func options(for rows: [MonitorEventRow]) -> [MonitorRuleBreadth] {
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
        options.append(.allDestinations)
        if single { options.append(.exactConnection) }
        return options
    }

    public static func target(
        _ breadth: MonitorRuleBreadth,
        for row: MonitorEventRow
    ) throws -> MonitorRuleTarget? {
        guard let seed = MonitorExactRuleSeed.make(from: row) else { return nil }
        let destination: DestinationCondition
        switch breadth {
        case .exactConnection:
            return MonitorRuleTarget(seed: seed)
        case .thisHost:
            destination = seed.destination
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
        port: UInt16?
    ) -> String {
        switch breadth {
        case .thisHost: "\(host), any port"
        case .allDestinations: "All destinations"
        case .exactConnection: port.map { "Only \(host) on port \($0)" } ?? "Only \(host)"
        }
    }

    /// The destination as it reads in a sentence about the rule.
    public static func phrase(_ breadth: MonitorRuleBreadth, host: String) -> String {
        switch breadth {
        case .thisHost: "\(host) on any port"
        case .allDestinations: "all destinations"
        case .exactConnection: host
        }
    }

    /// Hostname rules need a name from macOS, so say so where it matters.
    public static func limitation(_ breadth: MonitorRuleBreadth, row: MonitorEventRow) -> String? {
        guard breadth == .thisHost, row.event.flow.observedHostname != nil else { return nil }
        return "This applies to connections that use this name, not direct connections to its IP address."
    }
}

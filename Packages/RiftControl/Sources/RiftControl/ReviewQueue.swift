import Foundation
import RiftCore
import RiftIPC

/// What's left to decide after a week of watching: apps that connected with
/// no rule, and connections whose alert went unanswered. Built from history,
/// so it works in Allow and Watch, where nothing ever asks.
public struct ReviewQueue: Sendable, Hashable {
    public struct Destination: Sendable, Hashable {
        public let host: String
        public let firstSeen: Date
        public let lastSeen: Date
        public let count: Int
        /// The latest connection, for making a rule from it.
        public let row: MonitorEventRow
    }

    /// An app with at least one destination no rule decides yet.
    public struct App: Sendable, Hashable, Identifiable {
        public let id: String
        public let identity: ProcessIdentity
        /// Newest first.
        public let destinations: [Destination]

        public var lastSeen: Date { destinations.map(\.lastSeen).max() ?? .distantPast }
        public var newestFirstSeen: Date { destinations.map(\.firstSeen).max() ?? .distantPast }
        /// The latest connection, for an app-wide rule.
        public var row: MonitorEventRow { destinations[0].row }
    }

    /// An app and destination whose alert timed out or couldn't be shown.
    public struct Unanswered: Sendable, Hashable, Identifiable {
        public let id: String
        public let identity: ProcessIdentity
        public let host: String
        public let lastSeen: Date
        public let count: Int
        public let row: MonitorEventRow
    }

    public static let maximumUnanswered = 50

    public let apps: [App]
    public let unanswered: [Unanswered]

    public var isEmpty: Bool { apps.isEmpty && unanswered.isEmpty }

    public init(apps: [App], unanswered: [Unanswered]) {
        self.apps = apps
        self.unanswered = unanswered
    }

    /// The key Rift remembers an app by, the same on every launch.
    public static func key(for identity: ProcessIdentity) -> String {
        let data = (try? CanonicalPolicyJSON.encoder().encode(identity)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The connections worth checking against the current rules: the latest
    /// one for each app and destination that went undecided.
    public static func candidates(in rows: [MonitorEventRow]) -> [MonitorEventRow] {
        var keys = KeyCache()
        return candidates(in: rows, keys: &keys)
    }

    private static func candidates(in rows: [MonitorEventRow], keys: inout KeyCache) -> [MonitorEventRow] {
        var latest: [String: MonitorEventRow] = [:]
        for row in rows where kind(of: row) != nil {
            guard let identity = identity(of: row) else { continue }
            let key = keys.key(for: identity) + "\n" + destinationLabel(row)
            if let existing = latest[key], existing.event.occurredAt >= row.event.occurredAt { continue }
            latest[key] = row
        }
        return Array(latest.values)
    }

    /// Groups undecided connections by app.
    /// - Parameters:
    ///   - stillUndecided: the candidate rows no rule decides today, from
    ///     `candidates(in:)`. Anything a rule now covers is left out.
    ///   - dismissed: when the person chose Not Now for each app. An app comes
    ///     back once it contacts a destination it hadn't before.
    public static func build(
        rows: [MonitorEventRow],
        stillUndecided: Set<String>,
        dismissed: [String: Date]
    ) -> ReviewQueue {
        var noRule: [String: [String: [MonitorEventRow]]] = [:]
        var timedOut: [String: [String: [MonitorEventRow]]] = [:]
        var identities: [String: ProcessIdentity] = [:]
        var keys = KeyCache()
        for row in rows {
            guard let kind = kind(of: row), let identity = identity(of: row) else { continue }
            let app = keys.key(for: identity)
            identities[app] = identity
            let host = destinationLabel(row)
            switch kind {
            case .noRule: noRule[app, default: [:]][host, default: []].append(row)
            case .unanswered: timedOut[app, default: [:]][host, default: []].append(row)
            }
        }
        let decidedHosts = Set(candidates(in: rows, keys: &keys).filter { !stillUndecided.contains($0.id) }
            .map { destinationKey($0, keys: &keys) })

        let apps: [App] = noRule.compactMap { app, hosts in
            guard let identity = identities[app] else { return nil }
            let destinations = hosts.compactMap { host, rows -> Destination? in
                let sorted = rows.sorted { $0.event.occurredAt > $1.event.occurredAt }
                guard let latest = sorted.first, !decidedHosts.contains(app + "\n" + host) else { return nil }
                return Destination(
                    host: host, firstSeen: sorted.last?.event.occurredAt ?? latest.event.occurredAt,
                    lastSeen: latest.event.occurredAt, count: rows.count, row: latest
                )
            }.sorted { $0.lastSeen > $1.lastSeen }
            guard !destinations.isEmpty else { return nil }
            let value = App(id: app, identity: identity, destinations: destinations)
            if let since = dismissed[app], value.newestFirstSeen <= since { return nil }
            return value
        }.sorted { $0.lastSeen > $1.lastSeen }

        let unanswered: [Unanswered] = timedOut.flatMap { app, hosts in
            hosts.compactMap { host, rows -> Unanswered? in
                guard let identity = identities[app],
                      let latest = rows.max(by: { $0.event.occurredAt < $1.event.occurredAt }),
                      !decidedHosts.contains(app + "\n" + host) else { return nil }
                return Unanswered(
                    id: app + "\n" + host, identity: identity, host: host,
                    lastSeen: latest.event.occurredAt, count: rows.count, row: latest
                )
            }
        }.sorted { $0.lastSeen > $1.lastSeen }

        return ReviewQueue(apps: apps, unanswered: Array(unanswered.prefix(maximumUnanswered)))
    }

    private enum Kind { case noRule, unanswered }

    private static func kind(of row: MonitorEventRow) -> Kind? {
        guard row.event.kind == .decision else { return nil }
        switch row.event.cause {
        case .mode where row.event.tally == .noRule: return .noRule
        case .alertTimedOut, .alertUnavailable: return .unanswered
        default: return nil
        }
    }

    private static func identity(of row: MonitorEventRow) -> ProcessIdentity? {
        row.event.flow.sourceAppIdentity ?? row.event.flow.sourceProcessIdentity
    }

    private static func destinationKey(_ row: MonitorEventRow, keys: inout KeyCache) -> String {
        guard let identity = identity(of: row) else { return "" }
        return keys.key(for: identity) + "\n" + destinationLabel(row)
    }

    /// Encodes each identity once per pass, since a week of history repeats
    /// the same few apps many times.
    private struct KeyCache {
        private var values: [ProcessIdentity: String] = [:]

        mutating func key(for identity: ProcessIdentity) -> String {
            if let value = values[identity] { return value }
            let value = ReviewQueue.key(for: identity)
            values[identity] = value
            return value
        }
    }

    /// The destination's name, or its address when it arrived without one, so
    /// connections by address alone stay apart.
    public static func destinationLabel(_ row: MonitorEventRow) -> String {
        let flow = row.event.flow
        if flow.metadataConfidence.contains(.observedHostname), let name = flow.observedHostname { return name.ascii }
        guard let endpoint = flow.destinationEndpoint else { return String(localized: "Unknown destination", bundle: .module) }
        return endpoint.hostname?.ascii ?? endpoint.address.description
    }
}

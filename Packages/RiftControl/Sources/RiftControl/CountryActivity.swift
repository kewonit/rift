import Foundation
import RiftCore

/// Connections grouped by the country that routes their destination address.
public struct CountryActivity: Sendable, Hashable, Identifiable {
    public let countryCode: String
    public let connections: Int
    public let blocked: Int
    public let eventIDs: [String]
    public var id: String { countryCode }
    public var allBlocked: Bool { connections > 0 && blocked == connections }
}

public enum CountryActivityBuilder {
    /// Groups public destinations by country, most active first. Local, private,
    /// and unknown destinations are left out because they have no country.
    public static func build(
        _ rows: [MonitorDisplayRow],
        limit: Int = 12,
        countryCode: (IPAddress) -> String?
    ) -> [CountryActivity] {
        var totals: [String: (connections: Int, blocked: Int, ids: [String])] = [:]
        var cache: [IPAddress: String?] = [:]
        for row in rows {
            guard let endpoint = row.source.event.flow.destinationEndpoint,
                  endpoint.classes.isEmpty else { continue }
            let code: String?
            if let cached = cache[endpoint.address] {
                code = cached
            } else {
                code = countryCode(endpoint.address)
                if cache.count < 4_096 { cache[endpoint.address] = code }
            }
            guard let code else { continue }
            var value = totals[code] ?? (0, 0, [])
            value.connections += 1
            if row.source.event.action == .deny { value.blocked += 1 }
            if value.ids.count < 500 { value.ids.append(row.id) }
            totals[code] = value
        }
        return totals.map {
            CountryActivity(countryCode: $0.key, connections: $0.value.connections,
                            blocked: $0.value.blocked, eventIDs: $0.value.ids)
        }
        .sorted {
            $0.connections != $1.connections ? $0.connections > $1.connections : $0.countryCode < $1.countryCode
        }
        .prefix(max(0, limit))
        .map { $0 }
    }
}

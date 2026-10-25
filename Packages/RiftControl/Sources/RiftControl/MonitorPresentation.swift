import RiftCore
import Foundation

public enum ReportedByteTotal: Sendable, Hashable {
    case unavailable
    case lowerBound(UInt64)
    case exact(UInt64)

    public var value: UInt64? {
        switch self {
        case .unavailable: nil
        case .lowerBound(let value), .exact(let value): value
        }
    }

    public var isPartial: Bool {
        if case .lowerBound = self { return true }
        return false
    }
}

public struct MonitorRankedItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let count: Int
    public let presentationIdentity: ProcessIdentity?

    public init(
        id: String,
        label: String,
        count: Int,
        presentationIdentity: ProcessIdentity? = nil
    ) {
        self.id = id
        self.label = label
        self.count = count
        self.presentationIdentity = presentationIdentity
    }
}

public struct MonitorSummarySnapshot: Sendable, Hashable {
    public let processCount: Int
    public let destinationCount: Int
    public let allowed: Int
    public let denied: Int
    public let unresolved: Int
    public let incoming: Int
    public let sent: ReportedByteTotal
    public let received: ReportedByteTotal
    public let coverage: HistoryCoverage
    public let isComplete: Bool
    public let topApplications: [MonitorRankedItem]
    public let topDestinations: [MonitorRankedItem]

    public static let empty = MonitorSummarySnapshot(
        processCount: 0,
        destinationCount: 0,
        allowed: 0,
        denied: 0,
        unresolved: 0,
        incoming: 0,
        sent: .unavailable,
        received: .unavailable,
        coverage: .gap,
        isComplete: false,
        topApplications: [],
        topDestinations: []
    )

    public init(
        processCount: Int,
        destinationCount: Int,
        allowed: Int,
        denied: Int,
        unresolved: Int,
        incoming: Int,
        sent: ReportedByteTotal,
        received: ReportedByteTotal,
        coverage: HistoryCoverage,
        isComplete: Bool,
        topApplications: [MonitorRankedItem],
        topDestinations: [MonitorRankedItem]
    ) {
        self.processCount = processCount
        self.destinationCount = destinationCount
        self.allowed = allowed
        self.denied = denied
        self.unresolved = unresolved
        self.incoming = incoming
        self.sent = sent
        self.received = received
        self.coverage = coverage
        self.isComplete = isComplete
        self.topApplications = topApplications
        self.topDestinations = topDestinations
    }
}

public enum MonitorSummaryBuilder {
    public static func build(
        from rows: [MonitorDisplayRow],
        queryComplete: Bool = true,
        rangeCoverage: HistoryCoverage = .complete,
        topLimit: Int = 3
    ) -> MonitorSummarySnapshot {
        var applications: [ProcessIdentity?: SummaryGroup] = [:]
        var destinations: [SummaryDestination: SummaryGroup] = [:]
        var allowed = 0
        var denied = 0
        var unresolved = 0
        var incoming = 0
        var rowCoverage = HistoryCoverage.complete
        var sent = SummaryBytes()
        var received = SummaryBytes()
        for display in rows {
            let row = display.source
            let identity = row.event.flow.sourceAppIdentity ?? row.event.flow.sourceProcessIdentity
            if applications[identity] != nil { applications[identity]?.count += 1 }
            else { applications[identity] = SummaryGroup(first: row, count: 1) }
            let destination: SummaryDestination
            if let hostname = row.event.flow.observedHostname { destination = .hostname(hostname.ascii.lowercased()) }
            else if let endpoint = row.event.flow.destinationEndpoint { destination = .address(endpoint.address) }
            else { destination = .missing }
            if destinations[destination] != nil { destinations[destination]?.count += 1 }
            else { destinations[destination] = SummaryGroup(first: row, count: 1) }
            if row.event.reason != .concreteDecision { unresolved += 1 }
            else if row.event.action == .allow { allowed += 1 }
            else if row.event.action == .deny { denied += 1 }
            if row.event.flow.direction == .incoming { incoming += 1 }
            rowCoverage = .combined(rowCoverage, row.coverage)
            sent.add(row.bytesOutbound, closed: row.closedAt != nil)
            received.add(row.bytesInbound, closed: row.closedAt != nil)
        }
        let coverage = HistoryCoverage.combined(rowCoverage, rangeCoverage)
        return MonitorSummarySnapshot(
            processCount: applications.count, destinationCount: destinations.count,
            allowed: allowed, denied: denied, unresolved: unresolved, incoming: incoming,
            sent: sent.result(queryComplete: queryComplete, coverage: coverage),
            received: received.result(queryComplete: queryComplete, coverage: coverage),
            coverage: coverage, isComplete: queryComplete && coverage == .complete,
            topApplications: ranked(
                Array(applications.values), key: processKey, label: MonitorQuery.applicationLabel,
                identity: { $0.event.flow.sourceAppIdentity ?? $0.event.flow.sourceProcessIdentity }, limit: topLimit
            ),
            topDestinations: ranked(
                Array(destinations.values), key: destinationKey, label: destinationLabel, limit: topLimit
            )
        )
    }

    private enum SummaryDestination: Hashable {
        case hostname(String)
        case address(IPAddress)
        case missing
    }

    private struct SummaryGroup {
        let first: MonitorEventRow
        var count: Int
    }

    private struct SummaryBytes {
        var total: UInt64 = 0
        var measured = 0
        var complete = true
        var overflowed = false

        mutating func add(_ value: UInt64?, closed: Bool) {
            complete = complete && closed && value != nil
            guard let value else { return }
            measured += 1
            let result = total.addingReportingOverflow(value)
            overflowed = overflowed || result.overflow
            total = result.partialValue
        }

        func result(queryComplete: Bool, coverage: HistoryCoverage) -> ReportedByteTotal {
            guard measured > 0, !overflowed else { return .unavailable }
            return complete && queryComplete && coverage == .complete ? .exact(total) : .lowerBound(total)
        }
    }

    private static func ranked(
        _ groups: [SummaryGroup],
        key: (MonitorEventRow) -> String,
        label: (MonitorEventRow) -> String,
        identity: ((MonitorEventRow) -> ProcessIdentity?)? = nil,
        limit: Int
    ) -> [MonitorRankedItem] {
        guard limit > 0 else { return [] }
        return groups.map { group in
            MonitorRankedItem(
                id: key(group.first), label: DisplaySanitizer.plainText(label(group.first)),
                count: group.count, presentationIdentity: identity?(group.first)
            )
        }.sorted {
            if $0.count != $1.count { return $0.count > $1.count }
            let left = $0.label.lowercased(with: Locale(identifier: "en_US_POSIX"))
            let right = $1.label.lowercased(with: Locale(identifier: "en_US_POSIX"))
            if left != right { return left < right }
            return $0.id < $1.id
        }.prefix(limit).map { $0 }
    }

    private static func processKey(_ row: MonitorEventRow) -> String {
        String(reflecting: row.event.flow.sourceAppIdentity
            ?? row.event.flow.sourceProcessIdentity)
    }

    private static func destinationKey(_ row: MonitorEventRow) -> String {
        if let hostname = row.event.flow.observedHostname {
            return "host:\(hostname.ascii.lowercased())"
        }
        if let endpoint = row.event.flow.destinationEndpoint {
            return "ip:\(endpoint.address.description)"
        }
        return "missing"
    }

    private static func destinationLabel(_ row: MonitorEventRow) -> String {
        if let hostname = row.event.flow.observedHostname { return hostname.ascii }
        return row.event.flow.destinationEndpoint?.address.description ?? "Unknown destination"
    }
}

public enum CoarseMapCoordinateError: Error, Sendable, Equatable {
    case invalidCoordinate
}

public struct CoarseMapCoordinate: Sendable, Hashable {
    public static let quantization = 0.25
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite else {
            throw CoarseMapCoordinateError.invalidCoordinate
        }
        let clampedLatitude = min(max(latitude, -85), 85)
        let wrappedLongitude = Self.wrap(longitude)
        self.latitude = Self.quantize(clampedLatitude)
        self.longitude = Self.wrap(Self.quantize(wrappedLongitude))
    }

    private static func quantize(_ value: Double) -> Double {
        (value / quantization).rounded() * quantization
    }

    private static func wrap(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result >= 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }
}

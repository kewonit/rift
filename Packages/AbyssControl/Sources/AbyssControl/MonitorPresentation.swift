import AbyssCore
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
        let sources = rows.map(\.source)
        let concrete = sources.filter { $0.event.reason == .concreteDecision }
        let processKeys = Set(sources.map(processKey))
        let destinationKeys = Set(sources.map(destinationKey))
        let rowCoverage: HistoryCoverage = sources.contains { $0.coverage == .gap } ? .gap
            : sources.contains { $0.coverage == .partial } ? .partial : .complete
        let coverage = HistoryCoverage.combined(rowCoverage, rangeCoverage)
        return MonitorSummarySnapshot(
            processCount: processKeys.count,
            destinationCount: destinationKeys.count,
            allowed: concrete.filter { $0.event.action == .allow }.count,
            denied: concrete.filter { $0.event.action == .deny }.count,
            unresolved: sources.count - concrete.count,
            incoming: sources.filter { $0.event.flow.direction == .incoming }.count,
            sent: byteTotal(
                sources, value: \.bytesOutbound,
                queryComplete: queryComplete, coverage: coverage
            ),
            received: byteTotal(
                sources, value: \.bytesInbound,
                queryComplete: queryComplete, coverage: coverage
            ),
            coverage: coverage,
            isComplete: queryComplete && coverage == .complete,
            topApplications: ranked(
                sources, key: processKey, label: MonitorQuery.applicationLabel,
                identity: { $0.event.flow.sourceAppIdentity ?? $0.event.flow.sourceProcessIdentity },
                limit: topLimit
            ),
            topDestinations: ranked(
                sources, key: destinationKey, label: destinationLabel,
                limit: topLimit
            )
        )
    }

    private static func byteTotal(
        _ rows: [MonitorEventRow],
        value: KeyPath<MonitorEventRow, UInt64?>,
        queryComplete: Bool,
        coverage: HistoryCoverage
    ) -> ReportedByteTotal {
        let measured = rows.compactMap { $0[keyPath: value] }
        guard !measured.isEmpty else { return .unavailable }
        var total: UInt64 = 0
        for amount in measured {
            let result = total.addingReportingOverflow(amount)
            guard !result.overflow else { return .unavailable }
            total = result.partialValue
        }
        let complete = queryComplete && coverage == .complete && rows.allSatisfy {
            $0.closedAt != nil && $0[keyPath: value] != nil
        }
        return complete ? .exact(total) : .lowerBound(total)
    }

    private static func ranked(
        _ rows: [MonitorEventRow],
        key: (MonitorEventRow) -> String,
        label: (MonitorEventRow) -> String,
        identity: ((MonitorEventRow) -> ProcessIdentity?)? = nil,
        limit: Int
    ) -> [MonitorRankedItem] {
        guard limit > 0 else { return [] }
        var values: [String: (label: String, count: Int, identity: ProcessIdentity?)] = [:]
        for row in rows {
            let identifier = key(row)
            let current = values[identifier]
            values[identifier] = (
                current?.label ?? DisplaySanitizer.plainText(label(row)),
                (current?.count ?? 0) + 1,
                current?.identity ?? identity?(row)
            )
        }
        return values.map { id, value in
            MonitorRankedItem(
                id: id,
                label: value.label,
                count: value.count,
                presentationIdentity: value.identity
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

public struct CoarseMapCoordinate: Sendable, Hashable {
    public static let quantization = 0.25
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite else {
            throw GeoLocationError.invalidCoordinate
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

public struct MonitorMapPosition: Sendable, Hashable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, longitude.isFinite else {
            throw GeoLocationError.invalidCoordinate
        }
        self.latitude = min(max(latitude, -85), 85)
        self.longitude = MonitorMapGeometry.wrap(longitude)
    }
}

public struct MonitorMapViewport: Sendable, Hashable {
    public let centerLatitude: Double
    public let centerLongitude: Double
    public let latitudeDelta: Double
    public let longitudeDelta: Double

    public init(
        centerLatitude: Double,
        centerLongitude: Double,
        latitudeDelta: Double,
        longitudeDelta: Double
    ) {
        self.centerLatitude = centerLatitude
        self.centerLongitude = centerLongitude
        self.latitudeDelta = latitudeDelta
        self.longitudeDelta = longitudeDelta
    }
}

public enum MonitorMapGeometry {
    public static func viewport(for positions: [MonitorMapPosition]) -> MonitorMapViewport? {
        guard let first = positions.first else { return nil }
        let latitudes = positions.map(\.latitude)
        let minimumLatitude = latitudes.min() ?? first.latitude
        let maximumLatitude = latitudes.max() ?? first.latitude
        let latitudeDelta = min(170, max(2, (maximumLatitude - minimumLatitude) * 1.35))
        let latitudeLimit = 85 - latitudeDelta / 2
        let centerLatitude = min(
            max((minimumLatitude + maximumLatitude) / 2, -latitudeLimit), latitudeLimit
        )

        let longitudes = positions.map { positiveLongitude($0.longitude) }.sorted()
        var largestGap = -1.0
        var arcStart = longitudes[0]
        for index in longitudes.indices {
            let next = index == longitudes.index(before: longitudes.endIndex)
                ? longitudes[0] + 360 : longitudes[index + 1]
            let gap = next - longitudes[index]
            if gap > largestGap {
                largestGap = gap
                arcStart = next.truncatingRemainder(dividingBy: 360)
            }
        }
        let longitudeSpan = max(0, 360 - largestGap)
        let longitudeDelta = min(360, max(2, longitudeSpan * 1.18))
        let centerLongitude = wrap(arcStart + longitudeSpan / 2)
        return MonitorMapViewport(
            centerLatitude: centerLatitude,
            centerLongitude: centerLongitude,
            latitudeDelta: latitudeDelta,
            longitudeDelta: longitudeDelta
        )
    }

    fileprivate static func wrap(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result >= 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }

    private static func positiveLongitude(_ value: Double) -> Double {
        let wrapped = wrap(value)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }
}

public struct MonitorMapCandidate: Sendable, Hashable, Identifiable {
    public let id: String
    public let location: GeoLocation
    public let count: Int

    public init(id: String, location: GeoLocation, count: Int) {
        self.id = id
        self.location = location
        self.count = count
    }
}

public struct MonitorMapSelection: Sendable, Hashable {
    public let markers: [MonitorMapCandidate]
    public let links: [MonitorMapCandidate]
    public let totalLocationCount: Int

    public init(
        markers: [MonitorMapCandidate],
        links: [MonitorMapCandidate],
        totalLocationCount: Int
    ) {
        self.markers = markers
        self.links = links
        self.totalLocationCount = totalLocationCount
    }
}

public enum MonitorMapSelector {
    public static func select(
        from rows: [MonitorDisplayRow],
        selectedID: String?,
        markerLimit: Int = 200,
        linkLimit: Int = 32
    ) -> MonitorMapSelection {
        var grouped: [String: (location: GeoLocation, count: Int)] = [:]
        for row in rows {
            guard let location = row.geography.location else { continue }
            let id = location.stableID
            grouped[id] = (location, (grouped[id]?.count ?? 0) + 1)
        }
        let ranked = grouped.map { id, value in
            MonitorMapCandidate(id: id, location: value.location, count: value.count)
        }.sorted {
            if $0.id == selectedID || $1.id == selectedID {
                return $0.id == selectedID && $1.id != selectedID
            }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.id < $1.id
        }
        let markers = Array(ranked.prefix(max(0, min(markerLimit, 200))))
        let links = Array(markers.prefix(max(0, min(linkLimit, 32))))
        return MonitorMapSelection(
            markers: markers,
            links: links,
            totalLocationCount: ranked.count
        )
    }
}

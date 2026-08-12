import RiftCore
import Foundation

public enum GeoLocationError: Error, Sendable, Equatable {
    case invalidCoordinate
    case invalidCountryCode
}

public struct GeoLocation: Sendable, Hashable {
    public let continentCode: String
    public let countryCode: String
    public let region: String
    public let city: String
    public let latitude: Double
    public let longitude: Double

    public init(
        continentCode: String,
        countryCode: String,
        region: String,
        city: String,
        latitude: Double,
        longitude: Double
    ) throws {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else {
            throw GeoLocationError.invalidCoordinate
        }
        let normalizedCountry = countryCode.uppercased()
        guard normalizedCountry.isEmpty || Self.isRegionCode(normalizedCountry) else {
            throw GeoLocationError.invalidCountryCode
        }
        self.continentCode = continentCode.uppercased()
        self.countryCode = normalizedCountry
        self.region = region
        self.city = city
        self.latitude = latitude
        self.longitude = longitude
    }

    public var countryName: String {
        guard !countryCode.isEmpty else { return "Unknown country" }
        return Locale.autoupdatingCurrent.localizedString(forRegionCode: countryCode)
            ?? countryCode
    }

    public var displayName: String {
        let locality = city.isEmpty ? region : city
        return locality.isEmpty ? countryName : "\(locality), \(countryName)"
    }

    public var stableID: String {
        [countryCode, region, city, String(latitude), String(longitude)]
            .joined(separator: "|")
    }

    private static func isRegionCode(_ value: String) -> Bool {
        value.count == 2 && value.utf8.allSatisfy { (65...90).contains($0) }
    }
}

public enum GeoNonGeographicReason: String, Sendable, Hashable, CaseIterable {
    case missingEndpoint
    case loopback
    case linkLocal
    case localNetwork
    case multicast
    case broadcast
    case bonjour

    public var label: String {
        switch self {
        case .missingEndpoint: "Missing endpoint"
        case .loopback: "Loopback"
        case .linkLocal: "Link-local"
        case .localNetwork: "Local network"
        case .multicast: "Multicast"
        case .broadcast: "Broadcast"
        case .bonjour: "Bonjour"
        }
    }
}

public enum GeoResolution: Sendable, Hashable {
    case located(GeoLocation)
    case nonGeographic(GeoNonGeographicReason)
    case notFound

    public var displayName: String {
        switch self {
        case .located(let location): location.displayName
        case .nonGeographic(let reason): reason.label
        case .notFound: "Location unavailable"
        }
    }

    public var searchableText: String {
        switch self {
        case .located(let location):
            [location.continentCode, location.countryCode, location.countryName,
             location.region, location.city].joined(separator: " ")
        case .nonGeographic(let reason): reason.label
        case .notFound: "location unavailable unknown"
        }
    }

    public var location: GeoLocation? {
        guard case .located(let value) = self else { return nil }
        return value
    }
}

public struct GeoDatabaseMetadata: Sendable, Hashable {
    public let sourceName: String
    public let sourceVersion: String
    public let sourceModifiedAt: Date?
    public let importedAt: Date
    public let recordCount: Int

    public init(
        sourceName: String,
        sourceVersion: String,
        sourceModifiedAt: Date?,
        importedAt: Date,
        recordCount: Int
    ) {
        self.sourceName = sourceName
        self.sourceVersion = sourceVersion
        self.sourceModifiedAt = sourceModifiedAt
        self.importedAt = importedAt
        self.recordCount = recordCount
    }
}

public enum GeoEndpointClassifier {
    public static func nonGeographic(_ endpoint: Endpoint?) -> GeoResolution? {
        guard let endpoint else { return .nonGeographic(.missingEndpoint) }
        let classes = endpoint.classes
        if classes.contains(.loopback) { return .nonGeographic(.loopback) }
        if classes.contains(.bonjour) { return .nonGeographic(.bonjour) }
        if classes.contains(.broadcast) { return .nonGeographic(.broadcast) }
        if classes.contains(.multicast) { return .nonGeographic(.multicast) }
        if classes.contains(.localNetwork) { return .nonGeographic(.localNetwork) }
        if classes.contains(.linkLocal) { return .nonGeographic(.linkLocal) }
        return nil
    }
}

import RiftControl
import RiftCore
import Foundation
import Observation

@MainActor
@Observable
final class GeolocationController {
    private(set) var metadata: GeoDatabaseMetadata?
    private(set) var statusMessage = "No offline location database is installed."
    private(set) var isImporting = false
    private(set) var canImport = false
    private var repository: GeoRepository?
    private var databaseURL: URL?
    private var started = false
#if DEBUG
    private let fixtureEnabled: Bool

    init(fixtureEnabled: Bool = false) {
        self.fixtureEnabled = fixtureEnabled
    }
#else
    init() {}
#endif

    var isAvailable: Bool {
#if DEBUG
        if fixtureEnabled { return true }
#endif
        return repository != nil
    }

    var isMapUIAdmitted: Bool {
#if DEBUG
        fixtureEnabled
#else
        false
#endif
    }

    func start() async {
        guard !started else { return }
        started = true
#if DEBUG
        if fixtureEnabled {
            metadata = MonitorFixtureData.geoMetadata
            statusMessage = "Preview database loaded. No live traffic is being filtered."
            canImport = false
            return
        }
#endif
        guard let group = Bundle.main.object(
            forInfoDictionaryKey: "RiftAppGroupIdentifier"
        ) as? String,
              let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: group
              ) else {
            statusMessage = "The app-group storage container is unavailable."
            return
        }
        let support = container.appendingPathComponent("ControlPlane", isDirectory: true)
        let url = support.appendingPathComponent("geolocation.sqlite")
        databaseURL = url
        canImport = true
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let value = try await Task.detached(priority: .utility) {
                try GeoDatabase.openExisting(at: url)
            }.value
            repository = value
            metadata = value.metadata
            statusMessage = "Offline location database ready."
        } catch {
            statusMessage = "The existing location database failed validation and was not replaced."
        }
    }

    func importCSV() async {
        guard let databaseURL, !isImporting else { return }
        let previousRepository = repository
        let previousMetadata = metadata
        isImporting = true
        statusMessage = "Validating and indexing the local CSV…"
        defer { isImporting = false }
        do {
            guard let imported = try await GeoFileAccess.importCSV(to: databaseURL) else {
                statusMessage = previousRepository == nil
                    ? "No offline location database is installed."
                    : "Offline location database ready."
                return
            }
            let value = try await Task.detached(priority: .utility) {
                try GeoDatabase.openExisting(at: databaseURL)
            }.value
            repository = value
            metadata = imported
            statusMessage = "Offline location database imported successfully."
        } catch {
            repository = previousRepository
            metadata = previousMetadata
            statusMessage = previousRepository == nil
                ? "The CSV was rejected; no location database was installed."
                : "The CSV was rejected; the last valid database remains active."
        }
    }

    func resolutions(for rows: [MonitorEventRow]) async throws -> [String: GeoResolution] {
#if DEBUG
        if fixtureEnabled { return MonitorFixtureData.geography(for: rows) }
#endif
        guard let repository else {
            return Dictionary(uniqueKeysWithValues: rows.map { row in
                let value = GeoEndpointClassifier.nonGeographic(
                    row.event.flow.destinationEndpoint
                ) ?? .notFound
                return (row.id, value)
            })
        }
        return try await repository.resolve(rows.map {
            GeoLookupRequest(id: $0.id, endpoint: $0.event.flow.destinationEndpoint)
        })
    }

    func approximateNetworkLocation() async throws -> GeoLocation {
#if DEBUG
        if fixtureEnabled { return try MonitorFixtureData.approximateNetworkLocation() }
#endif
        guard let repository else { throw NetworkOriginError.databaseUnavailable }
        let address = try await PublicIPAddressLookup.fetch()
        let endpoint = Endpoint(
            address: address,
            port: nil,
            hostname: nil,
            hostnameCoverage: .absent,
            classes: EndpointClassifier.classify(
                address: address,
                observedHostname: nil,
                snapshot: nil
            ),
            interfaceSnapshotGeneration: 0
        )
        let result = try await repository.resolve([
            GeoLookupRequest(id: "network-origin", endpoint: endpoint),
        ])
        guard let location = result["network-origin"]?.location else {
            throw NetworkOriginError.locationUnavailable
        }
        return location
    }
}

private enum NetworkOriginError: Error {
    case databaseUnavailable
    case invalidResponse
    case locationUnavailable
}

@MainActor
@Observable
final class MonitorOriginController {
    var origin: CoarseMapOrigin?
    var isPlacingManually = false
    private(set) var isLocating = false
    private(set) var automaticLookupFailed = false
    @ObservationIgnored private var didAttemptAutomaticLookup = false
    @ObservationIgnored private var lookupTask: Task<Void, Never>?

    func locateAutomatically(using geolocation: GeolocationController) {
        guard !didAttemptAutomaticLookup else { return }
        didAttemptAutomaticLookup = true
        locate(using: geolocation)
    }

    func locate(using geolocation: GeolocationController) {
        guard origin == nil, !isLocating else { return }
        lookupTask?.cancel()
        isPlacingManually = false
        isLocating = true
        automaticLookupFailed = false
        lookupTask = Task { [weak self, weak geolocation] in
            guard let self, let geolocation else { return }
            do {
                let location = try await geolocation.approximateNetworkLocation()
                try Task.checkCancellation()
                origin = CoarseMapOrigin(coordinate: try CoarseMapCoordinate(
                    latitude: location.latitude,
                    longitude: location.longitude
                ))
            } catch is CancellationError {
                return
            } catch {
                automaticLookupFailed = true
            }
            isLocating = false
            lookupTask = nil
        }
    }

    func beginManualPlacement() {
        cancelLookup()
        isPlacingManually = true
    }

    func clearOrigin() {
        cancelLookup()
        origin = nil
    }

    func cancelPlacement() {
        isPlacingManually = false
    }

    func cancelLookup() {
        lookupTask?.cancel()
        lookupTask = nil
        isLocating = false
    }
}

private enum PublicIPAddressLookup {
    private static let endpoint = URL(string: "https://api64.ipify.org/")

    static func fetch() async throws -> IPAddress {
        guard let endpoint else { throw NetworkOriginError.invalidResponse }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 7
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: endpoint)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 5
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        let delegate = RedirectRejectingURLSessionDelegate()
        let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
        guard let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              http.url == endpoint else { throw NetworkOriginError.invalidResponse }

        var data = Data()
        for try await byte in bytes {
            guard data.count < PublicIPAddressResponse.maximumBytes else {
                throw PublicIPAddressResponseError.tooLarge
            }
            data.append(byte)
        }
        return try PublicIPAddressResponse.parse(data)
    }
}

private final class RedirectRejectingURLSessionDelegate: NSObject,
    URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

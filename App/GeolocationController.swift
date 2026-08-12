import RiftControl
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
}

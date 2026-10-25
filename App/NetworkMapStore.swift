import Foundation
import Observation
import RiftControl
import RiftCore

/// The bundled cable map, loaded once per launch.
struct NetworkMapResources: Sendable {
    let table: CountryIPTable
    let router: CableRouter
    let mappedCables: [[GeoPoint]]
    let estimatedRoutes: [[GeoPoint]]
    let source: String

    static func load(from directory: URL) throws -> NetworkMapResources {
        let table = try CountryIPTable(compressedData: Data(contentsOf: directory.appendingPathComponent("ip-country.bin")))
        let grid = try CountryGrid(compressedData: Data(contentsOf: directory.appendingPathComponent("country-grid.bin")))
        let network = try JSONDecoder().decode(
            UnderseaCableNetwork.self,
            from: Data(contentsOf: directory.appendingPathComponent("network-map.json"))
        )
        var mapped: [[GeoPoint]] = []
        var estimated: [[GeoPoint]] = []
        for segment in network.segments {
            let parts = NetworkMapGeometry.splitAtAntimeridian(segment.path)
            if network.cables[segment.cable].approximate {
                estimated.append(contentsOf: parts)
            } else {
                mapped.append(contentsOf: parts)
            }
        }
        return NetworkMapResources(
            table: table,
            router: CableRouter(network: network, grid: grid),
            mappedCables: mapped,
            estimatedRoutes: estimated,
            source: network.source
        )
    }
}

/// A country Rift's connections are going to, with its estimated path.
struct MapDestination: Identifiable, Hashable, Sendable {
    let activity: CountryActivity
    let route: CableRoute
    var id: String { activity.countryCode }
    var countryCode: String { activity.countryCode }

    var name: String {
        Locale.autoupdatingCurrent.localizedString(forRegionCode: countryCode) ?? countryCode
    }

    var summary: String {
        let connections = activity.connections == 1 ? "1 connection" : "\(activity.connections) connections"
        guard activity.blocked > 0 else { return connections }
        return "\(connections) · \(activity.blocked) blocked"
    }
}

@MainActor
@Observable
final class NetworkMapStore {
    static let shared = NetworkMapStore()

    private(set) var resources: NetworkMapResources?
    private(set) var loadFailed = false
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var routeCache: [String: CableRoute] = [:]

    private init() {}

    func load() {
        guard resources == nil, loadTask == nil else { return }
        guard let directory = Bundle.main.resourceURL else {
            loadFailed = true
            return
        }
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try NetworkMapResources.load(from: directory) }
            }.value
            guard let self else { return }
            switch result {
            case .success(let value): resources = value
            case .failure: loadFailed = true
            }
            loadTask = nil
        }
    }

    func countryCode(for address: IPAddress) -> String? {
        resources?.table.countryCode(for: address)
    }

    /// Estimated paths from the user's location to each active country.
    func destinations(
        for activity: [CountryActivity],
        origin: CoarseMapCoordinate?
    ) async -> [MapDestination] {
        guard let resources, let origin else { return [] }
        let start = GeoPoint(latitude: origin.latitude, longitude: origin.longitude)
        let prefix = "\(origin.latitude),\(origin.longitude)|"
        let missing = activity.map(\.countryCode).filter { routeCache[prefix + $0] == nil }
        if !missing.isEmpty {
            let router = resources.router
            let computed = await Task.detached(priority: .userInitiated) {
                missing.map { ($0, router.route(from: start, toCountry: $0)) }
            }.value
            if routeCache.count > 2_000 { routeCache.removeAll() }
            for (code, route) in computed { routeCache[prefix + code] = route }
        }
        return activity.map {
            MapDestination(activity: $0, route: routeCache[prefix + $0.countryCode] ?? .unavailable)
        }
    }
}

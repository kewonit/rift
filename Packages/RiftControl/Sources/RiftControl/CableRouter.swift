import Foundation

public struct CableRouteLeg: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case cable(name: String, approximate: Bool)
        case land
    }

    public let kind: Kind
    public let points: [GeoPoint]
}

public enum CableRoute: Sendable, Hashable {
    /// The destination is in the same country as the origin.
    case domestic(destination: GeoPoint)
    /// The likely path stays on land.
    case overland(destination: GeoPoint)
    /// The likely path uses one or more undersea cables.
    case undersea(legs: [CableRouteLeg], destination: GeoPoint)
    /// Rift has no location for this country or no path from the origin.
    case unavailable

    public var destination: GeoPoint? {
        switch self {
        case .domestic(let point), .overland(let point), .undersea(_, let point): point
        case .unavailable: nil
        }
    }
}

/// Estimates which undersea cables a connection most likely uses, from the
/// origin the user placed to the country that routes the destination address.
/// This is a shortest-path estimate over the bundled cable map, not an observed route.
public struct CableRouter: Sendable {
    private struct Edge: Sendable {
        let to: Int
        let weight: Double
        /// A cable segment index, or nil for an overland link.
        let segment: Int?
    }

    static let landWeight = 1.8
    /// Added to every hop so the estimate prefers fewer, longer cables.
    static let hopPenalty = 150.0
    static let originReachKilometers = 1_200.0
    static let destinationReachKilometers = 1_000.0
    static let directOverlandKilometers = 2_500.0
    static let overlandShare = 0.75

    private let network: UnderseaCableNetwork
    private let grid: CountryGrid
    private let adjacency: [[Edge]]
    private let landings: [Int]

    public init(network: UnderseaCableNetwork, grid: CountryGrid) {
        self.network = network
        self.grid = grid
        var adjacency = Array(repeating: [Edge](), count: network.nodes.count)
        for (index, segment) in network.segments.enumerated() {
            let weight = segment.kilometers + Self.hopPenalty
            adjacency[segment.from].append(Edge(to: segment.to, weight: weight, segment: index))
            adjacency[segment.to].append(Edge(to: segment.from, weight: weight, segment: index))
        }
        for link in network.landLinks {
            let weight = link.kilometers * Self.landWeight + Self.hopPenalty
            adjacency[link.from].append(Edge(to: link.to, weight: weight, segment: nil))
            adjacency[link.to].append(Edge(to: link.from, weight: weight, segment: nil))
        }
        self.adjacency = adjacency
        landings = network.nodes.indices.filter { !network.nodes[$0].countryCode.isEmpty }
    }

    public func countryCode(at point: GeoPoint) -> String? {
        grid.nearestCountryCode(to: point)
    }

    public func route(from origin: GeoPoint, toCountry code: String) -> CableRoute {
        guard let destination = network.countries[code] else { return .unavailable }
        let originCountry = grid.nearestCountryCode(to: origin)
        if originCountry == code { return .domestic(destination: destination) }

        let originNode = network.nodes.count
        let destinationNode = originNode + 1
        var extra: [Int: [Edge]] = [:]
        for node in landings {
            let point = network.nodes[node].point
            let country = network.nodes[node].countryCode
            let fromOrigin = NetworkMapGeometry.kilometers(origin, point)
            if country == originCountry
                || (fromOrigin <= Self.originReachKilometers
                    && grid.landShare(from: origin, to: point) >= Self.overlandShare) {
                extra[originNode, default: []].append(
                    Edge(to: node, weight: fromOrigin * Self.landWeight + Self.hopPenalty, segment: nil)
                )
            }
            let toDestination = NetworkMapGeometry.kilometers(point, destination)
            if country == code
                || (toDestination <= Self.destinationReachKilometers
                    && grid.landShare(from: point, to: destination) >= Self.overlandShare) {
                extra[node, default: []].append(
                    Edge(to: destinationNode, weight: toDestination * Self.landWeight + Self.hopPenalty, segment: nil)
                )
            }
        }
        let direct = NetworkMapGeometry.kilometers(origin, destination)
        if direct <= Self.directOverlandKilometers,
           grid.landShare(from: origin, to: destination) >= Self.overlandShare {
            extra[originNode, default: []].append(
                Edge(to: destinationNode, weight: direct * Self.landWeight, segment: nil)
            )
        }

        guard let path = shortestPath(from: originNode, to: destinationNode, extra: extra) else {
            return .unavailable
        }
        guard path.contains(where: { $0.edge.segment != nil }) else {
            return .overland(destination: destination)
        }

        func point(_ node: Int) -> GeoPoint {
            node == originNode ? origin : node == destinationNode ? destination : network.nodes[node].point
        }
        var legs: [CableRouteLeg] = []
        for step in path {
            if let index = step.edge.segment {
                let segment = network.segments[index]
                let cable = network.cables[segment.cable]
                let points = segment.from == step.from ? segment.path : segment.path.reversed()
                legs.append(CableRouteLeg(kind: .cable(name: cable.name, approximate: cable.approximate), points: points))
            } else if let last = legs.last, last.kind == .land {
                legs[legs.count - 1] = CableRouteLeg(kind: .land, points: last.points + [point(step.edge.to)])
            } else {
                legs.append(CableRouteLeg(kind: .land, points: [point(step.from), point(step.edge.to)]))
            }
        }
        return .undersea(legs: legs, destination: destination)
    }

    private func shortestPath(
        from start: Int,
        to goal: Int,
        extra: [Int: [Edge]]
    ) -> [(from: Int, edge: Edge)]? {
        let count = network.nodes.count + 2
        var distance = Array(repeating: Double.infinity, count: count)
        var previous = Array<(from: Int, edge: Edge)?>(repeating: nil, count: count)
        var heap = MinimumHeap()
        distance[start] = 0
        heap.push(0, start)
        while let (spent, node) = heap.pop() {
            if node == goal { break }
            guard spent <= distance[node] else { continue }
            let edges = (node < adjacency.count ? adjacency[node] : []) + (extra[node] ?? [])
            for edge in edges {
                let total = spent + edge.weight
                if total < distance[edge.to] {
                    distance[edge.to] = total
                    previous[edge.to] = (node, edge)
                    heap.push(total, edge.to)
                }
            }
        }
        guard distance[goal].isFinite else { return nil }
        var steps: [(from: Int, edge: Edge)] = []
        var node = goal
        while let step = previous[node] {
            steps.append(step)
            node = step.from
        }
        return steps.reversed()
    }
}

private struct MinimumHeap {
    private var items: [(Double, Int)] = []

    mutating func push(_ priority: Double, _ value: Int) {
        items.append((priority, value))
        var child = items.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].0 < items[parent].0 else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> (Double, Int)? {
        guard !items.isEmpty else { return nil }
        items.swapAt(0, items.count - 1)
        let result = items.removeLast()
        var parent = 0
        while true {
            let left = parent * 2 + 1
            let right = left + 1
            var smallest = parent
            if left < items.count, items[left].0 < items[smallest].0 { smallest = left }
            if right < items.count, items[right].0 < items[smallest].0 { smallest = right }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
        return result
    }
}

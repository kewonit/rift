import Foundation

/// Bundled undersea cable map: cable paths, the landing points they connect,
/// overland links between nearby landing points, and a label point per country.
public struct UnderseaCableNetwork: Sendable, Decodable {
    public struct Cable: Sendable, Hashable, Decodable {
        public let name: String
        /// True for main sea routes drawn from their landing points rather than
        /// from mapped cable geometry.
        public let approximate: Bool
    }

    public struct Node: Sendable, Hashable {
        public let point: GeoPoint
        /// Empty for junctions at sea.
        public let countryCode: String
    }

    public struct Segment: Sendable, Hashable {
        public let cable: Int
        public let from: Int
        public let to: Int
        public let kilometers: Double
        public let path: [GeoPoint]
    }

    public struct LandLink: Sendable, Hashable {
        public let from: Int
        public let to: Int
        public let kilometers: Double
    }

    public let source: String
    public let countries: [String: GeoPoint]
    public let cables: [Cable]
    public let nodes: [Node]
    public let segments: [Segment]
    public let landLinks: [LandLink]

    private enum CodingKeys: String, CodingKey {
        case format, source, countries, cables, nodes, segments, landLinks
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .format) == 1 else {
            throw NetworkDataError.invalidFormat
        }
        source = try container.decode(String.self, forKey: .source)
        countries = try container.decode([String: [Double]].self, forKey: .countries)
            .compactMapValues { $0.count == 2 ? GeoPoint(latitude: $0[0], longitude: $0[1]) : nil }
        cables = try container.decode([Cable].self, forKey: .cables)

        var nodeList = try container.nestedUnkeyedContainer(forKey: .nodes)
        var nodes: [Node] = []
        while !nodeList.isAtEnd {
            var item = try nodeList.nestedUnkeyedContainer()
            let point = GeoPoint(latitude: try item.decode(Double.self), longitude: try item.decode(Double.self))
            nodes.append(Node(point: point, countryCode: try item.decode(String.self)))
        }
        self.nodes = nodes

        var segmentList = try container.nestedUnkeyedContainer(forKey: .segments)
        var segments: [Segment] = []
        while !segmentList.isAtEnd {
            var item = try segmentList.nestedUnkeyedContainer()
            let cable = try item.decode(Int.self)
            let from = try item.decode(Int.self)
            let to = try item.decode(Int.self)
            let kilometers = try item.decode(Double.self)
            let path = try item.decode([[Double]].self).compactMap {
                $0.count == 2 ? GeoPoint(latitude: $0[0], longitude: $0[1]) : nil
            }
            segments.append(Segment(cable: cable, from: from, to: to, kilometers: kilometers, path: path))
        }
        self.segments = segments

        var linkList = try container.nestedUnkeyedContainer(forKey: .landLinks)
        var links: [LandLink] = []
        while !linkList.isAtEnd {
            var item = try linkList.nestedUnkeyedContainer()
            links.append(LandLink(
                from: try item.decode(Int.self),
                to: try item.decode(Int.self),
                kilometers: try item.decode(Double.self)
            ))
        }
        landLinks = links

        let nodeRange = 0..<nodes.count
        guard segments.allSatisfy({
            cables.indices.contains($0.cable) && nodeRange.contains($0.from)
                && nodeRange.contains($0.to) && $0.path.count >= 2
        }), links.allSatisfy({ nodeRange.contains($0.from) && nodeRange.contains($0.to) }) else {
            throw NetworkDataError.invalidFormat
        }
    }
}

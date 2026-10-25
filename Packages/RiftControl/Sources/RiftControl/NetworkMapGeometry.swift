import Foundation

/// A latitude/longitude pair in degrees.
public struct GeoPoint: Sendable, Hashable, Codable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public enum NetworkMapGeometry {
    public static func kilometers(_ start: GeoPoint, _ end: GeoPoint) -> Double {
        let startLatitude = start.latitude * .pi / 180
        let endLatitude = end.latitude * .pi / 180
        let latitudeDelta = endLatitude - startLatitude
        let longitudeDelta = wrapLongitude(end.longitude - start.longitude) * .pi / 180
        let value = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(startLatitude) * cos(endLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return 6_371 * 2 * atan2(sqrt(value), sqrt(max(0, 1 - value)))
    }

    public static func wrapLongitude(_ value: Double) -> Double {
        var result = value.truncatingRemainder(dividingBy: 360)
        if result > 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result
    }

    /// Splits a path wherever it crosses the 180° meridian so map overlays never
    /// draw a line the long way around the world.
    public static func splitAtAntimeridian(_ points: [GeoPoint]) -> [[GeoPoint]] {
        guard var previous = points.first else { return [] }
        var parts: [[GeoPoint]] = [[previous]]
        for point in points.dropFirst() {
            let delta = point.longitude - previous.longitude
            if abs(delta) > 180 {
                let eastward = delta < 0
                let edge: Double = eastward ? 180 : -180
                let unwrapped = point.longitude + (eastward ? 360 : -360)
                let fraction = (edge - previous.longitude) / (unwrapped - previous.longitude)
                let latitude = previous.latitude + (point.latitude - previous.latitude) * fraction
                parts[parts.count - 1].append(GeoPoint(latitude: latitude, longitude: edge))
                parts.append([GeoPoint(latitude: latitude, longitude: -edge)])
            }
            parts[parts.count - 1].append(point)
            previous = point
        }
        return parts.filter { $0.count > 1 }
    }
}

enum NetworkDataError: Error, Sendable, Equatable {
    case invalidFormat
    case truncated
}

struct NetworkDataReader {
    private let bytes: [UInt8]
    private(set) var offset = 0

    init(_ data: Data) { bytes = Array(data) }

    static func inflate(_ data: Data) throws -> Data {
        do {
            return try (data as NSData).decompressed(using: .zlib) as Data
        } catch {
            throw NetworkDataError.invalidFormat
        }
    }

    mutating func expect(_ magic: String) throws {
        let expected = Array(magic.utf8)
        guard try take(expected.count) == expected else { throw NetworkDataError.invalidFormat }
    }

    mutating func take(_ count: Int) throws -> [UInt8] {
        guard count >= 0, offset + count <= bytes.count else { throw NetworkDataError.truncated }
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    mutating func uint8() throws -> UInt8 { try take(1)[0] }

    mutating func uint16() throws -> UInt16 {
        let value = try take(2)
        return UInt16(value[0]) | UInt16(value[1]) << 8
    }

    mutating func uint32() throws -> UInt32 {
        try take(4).enumerated().reduce(0) { $0 | UInt32($1.element) << (8 * UInt32($1.offset)) }
    }

    mutating func varint() throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while true {
            let byte = try uint8()
            guard shift < 64 else { throw NetworkDataError.invalidFormat }
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
        }
    }

    mutating func countryCodes(_ count: Int) throws -> [String] {
        let raw = try take(count * 2)
        return (0..<count).map { String(decoding: raw[$0 * 2..<$0 * 2 + 2], as: UTF8.self) }
    }
}

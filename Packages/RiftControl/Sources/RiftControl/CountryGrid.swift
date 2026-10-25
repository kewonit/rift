import Foundation

/// A coarse world grid that says which country, if any, covers each cell.
public struct CountryGrid: Sendable {
    public let width: Int
    public let height: Int
    private let codes: [String]
    private let cells: [UInt8]

    public init(compressedData: Data) throws {
        var reader = NetworkDataReader(try NetworkDataReader.inflate(compressedData))
        try reader.expect("RIFTCG01")
        width = Int(try reader.uint16())
        height = Int(try reader.uint16())
        let codeCount = Int(try reader.uint8())
        let codes = [""] + (try reader.countryCodes(codeCount))
        self.codes = codes
        guard width > 0, height > 0, width == height * 2 else { throw NetworkDataError.invalidFormat }
        var cells: [UInt8] = []
        cells.reserveCapacity(width * height)
        for _ in 0..<height {
            let runs = Int(try reader.uint16())
            var filled = 0
            for _ in 0..<runs {
                let length = Int(try reader.uint16())
                let value = try reader.uint8()
                guard Int(value) < codes.count, filled + length <= width else {
                    throw NetworkDataError.invalidFormat
                }
                cells.append(contentsOf: repeatElement(value, count: length))
                filled += length
            }
            guard filled == width else { throw NetworkDataError.invalidFormat }
        }
        self.cells = cells
    }

    private var step: Double { 360 / Double(width) }

    private func cell(_ point: GeoPoint) -> (row: Int, column: Int) {
        let row = min(height - 1, max(0, Int((90 - point.latitude) / step)))
        let longitude = NetworkMapGeometry.wrapLongitude(point.longitude)
        let column = min(width - 1, max(0, Int((longitude + 180) / step)))
        return (row, column)
    }

    public func countryCode(at point: GeoPoint) -> String? {
        let (row, column) = cell(point)
        let value = cells[row * width + column]
        return value == 0 ? nil : codes[Int(value)]
    }

    public func isLand(_ point: GeoPoint) -> Bool { countryCode(at: point) != nil }

    /// The country of the nearest land cell within `radius` cells.
    public func nearestCountryCode(to point: GeoPoint, radius: Int = 4) -> String? {
        let (row, column) = cell(point)
        var best: (value: UInt8, distance: Int)?
        for rowOffset in -radius...radius {
            let candidateRow = row + rowOffset
            guard (0..<height).contains(candidateRow) else { continue }
            for columnOffset in -radius...radius {
                let candidateColumn = (column + columnOffset + width) % width
                let value = cells[candidateRow * width + candidateColumn]
                let distance = rowOffset * rowOffset + columnOffset * columnOffset
                if value != 0, distance < (best?.distance ?? .max) {
                    best = (value, distance)
                }
            }
        }
        return best.map { codes[Int($0.value)] }
    }

    /// The share of a straight path, sampled about every 20 km, that lies over land.
    public func landShare(from start: GeoPoint, to end: GeoPoint) -> Double {
        let kilometers = NetworkMapGeometry.kilometers(start, end)
        let samples = max(2, Int(kilometers / 20))
        var endLongitude = end.longitude
        if endLongitude - start.longitude > 180 { endLongitude -= 360 }
        if endLongitude - start.longitude < -180 { endLongitude += 360 }
        var land = 0
        for index in 0...samples {
            let fraction = Double(index) / Double(samples)
            let point = GeoPoint(
                latitude: start.latitude + (end.latitude - start.latitude) * fraction,
                longitude: start.longitude + (endLongitude - start.longitude) * fraction
            )
            if isLand(point) { land += 1 }
        }
        return Double(land) / Double(samples + 1)
    }
}

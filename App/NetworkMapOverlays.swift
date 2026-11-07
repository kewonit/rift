import AppKit
import MapKit
import QuartzCore
import RiftControl

enum NetworkMapStyle: String, CaseIterable, Identifiable {
    case standard
    case satellite

    var id: String { rawValue }
    var title: String { self == .standard ? "Map" : "Satellite" }

    var configuration: MKMapConfiguration {
        switch self {
        case .standard:
            let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
            configuration.pointOfInterestFilter = .excludingAll
            configuration.showsTraffic = false
            return configuration
        case .satellite:
            let configuration = MKHybridMapConfiguration(elevationStyle: .flat)
            configuration.pointOfInterestFilter = .excludingAll
            configuration.showsTraffic = false
            return configuration
        }
    }
}

extension GeoPoint {
    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// The whole cable network, drawn as one faint overlay.
final class CableNetworkOverlay: MKMultiPolyline {
    private(set) var isEstimated = false

    static func make(paths: [[GeoPoint]], estimated: Bool) -> CableNetworkOverlay {
        let polylines = paths.map { path -> MKPolyline in
            let coordinates = path.map(\.mapCoordinate)
            return MKPolyline(coordinates: coordinates, count: coordinates.count)
        }
        let overlay = CableNetworkOverlay(polylines)
        overlay.isEstimated = estimated
        return overlay
    }
}

/// One leg of a highlighted route to a destination country.
final class RouteLegPolyline: MKPolyline {
    private(set) var countryCode = ""
    private(set) var isCable = true

    static func make(_ points: [GeoPoint], countryCode: String, isCable: Bool) -> RouteLegPolyline {
        let coordinates = points.map(\.mapCoordinate)
        let polyline = RouteLegPolyline(coordinates: coordinates, count: coordinates.count)
        polyline.countryCode = countryCode
        polyline.isCable = isCable
        return polyline
    }
}

final class OriginAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String? = "This Mac"

    init(coordinate: CLLocationCoordinate2D) { self.coordinate = coordinate }
}

final class DestinationAnnotation: NSObject, MKAnnotation {
    private(set) var destination: MapDestination
    let coordinate: CLLocationCoordinate2D
    private(set) var title: String?
    private(set) var subtitle: String?

    init(destination: MapDestination, point: GeoPoint) {
        self.destination = destination
        coordinate = point.mapCoordinate
        title = destination.name
        subtitle = destination.summary
    }

    /// Refreshes counts without moving the marker; the route key guarantees the
    /// position is unchanged.
    func update(_ destination: MapDestination) {
        self.destination = destination
        subtitle = destination.summary
    }
}

/// The map is drawn like a chart: hairline cables as texture, and thin
/// single-color routes in the ink and teal of the app icon.
enum NetworkMapPalette {
    private static let ink = NSColor(srgbRed: 0.055, green: 0.235, blue: 0.345, alpha: 1)
    private static let teal = NSColor(srgbRed: 0.373, green: 0.890, blue: 0.839, alpha: 1)

    /// Satellite imagery is dark whatever the window's appearance.
    static func isOnDark(style: NetworkMapStyle, appearance: NSAppearance) -> Bool {
        style == .satellite || appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    static func resolved(_ color: NSColor, alpha: CGFloat, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(cgColor: color.withAlphaComponent(alpha).cgColor) ?? color
        }
        return result
    }

    static func cable(estimated: Bool, style: NetworkMapStyle, appearance: NSAppearance) -> NSColor {
        let base: NSColor = isOnDark(style: style, appearance: appearance) ? .white : ink
        return base.withAlphaComponent(estimated ? 0.08 : 0.14)
    }

    static let cableWidth: CGFloat = 0.5

    /// The solid color of routes and markers.
    static func mark(style: NetworkMapStyle, appearance: NSAppearance) -> NSColor {
        isOnDark(style: style, appearance: appearance) ? teal : ink
    }

    static func route(isCable: Bool, dimmed: Bool, style: NetworkMapStyle, appearance: NSAppearance) -> NSColor {
        let strength: CGFloat = isCable ? 0.95 : 0.55
        return mark(style: style, appearance: appearance).withAlphaComponent(dimmed ? 0.16 : strength)
    }

    static func routeWidth(isCable: Bool) -> CGFloat { isCable ? 1.5 : 1 }
}

/// Rounds a path's corners, so routes read as curves instead of a string of
/// straight pieces. Call it after splitting at the antimeridian: averaging across
/// that line would send the path around the world.
enum RouteSmoothing {
    private static let passes = 2

    static func smoothed(_ points: [GeoPoint]) -> [GeoPoint] {
        guard points.count > 2 else { return points }
        var path = points.map { (lat: $0.latitude, lon: $0.longitude) }
        for _ in 0..<passes {
            var next = [path[0]]
            next.reserveCapacity(path.count * 2)
            for (start, end) in zip(path, path.dropFirst()) {
                next.append((start.lat * 0.75 + end.lat * 0.25, start.lon * 0.75 + end.lon * 0.25))
                next.append((start.lat * 0.25 + end.lat * 0.75, start.lon * 0.25 + end.lon * 0.75))
            }
            next.append(path[path.count - 1])
            path = next
        }
        return path.map { GeoPoint(latitude: $0.lat, longitude: $0.lon) }
    }
}

/// A few small dots that travel along the routes in focus. Moving a tiny layer
/// along a path is cheap for the window server, unlike animating a dash
/// pattern, which redraws the whole stroked path every frame. Dots hide while
/// the map moves and are re-projected once it stops.
final class FlowOverlayView: NSView {
    struct Flow: Equatable {
        let id: String
        let points: [GeoPoint]
    }

    private static let dotsPerRoute = 1
    private static let pointsPerSecond: Double = 90
    private var flows: [Flow] = []
    private var tracks: [CALayer] = []
    private var regionChanging = false
    private weak var mapView: MKMapView?
    var animates = true {
        didSet { if animates != oldValue { rebuild() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setFlows(_ newFlows: [Flow], mapView: MKMapView) {
        self.mapView = mapView
        guard newFlows != flows else { return }
        flows = newFlows
        rebuild()
    }

    func regionWillChange() {
        guard !regionChanging else { return }
        regionChanging = true
        rebuild()
    }

    func regionDidChange() {
        regionChanging = false
        rebuild()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    private func rebuild() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        tracks.forEach { $0.removeFromSuperlayer() }
        tracks = []
        guard animates, !regionChanging, let mapView, let root = layer else { return }
        let fill = NetworkMapPalette.resolved(.white, alpha: 1, in: effectiveAppearance).cgColor
        for flow in flows {
            guard let (path, length) = longestRun(of: flow.points, in: mapView), length > 40 else { continue }
            let duration = min(max(Double(length) / Self.pointsPerSecond, 2.5), 9)
            let track = CALayer()
            track.frame = bounds
            for index in 0..<Self.dotsPerRoute {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: 3, height: 3)
                dot.cornerRadius = 1.5
                dot.backgroundColor = fill
                let animation = CAKeyframeAnimation(keyPath: "position")
                animation.path = path
                animation.calculationMode = .paced
                animation.duration = duration
                animation.repeatCount = .infinity
                animation.timeOffset = duration * Double(index) / Double(Self.dotsPerRoute)
                animation.preferredFrameRateRange = CAFrameRateRange(minimum: 12, maximum: 30, preferred: 24)
                dot.add(animation, forKey: "flow")
                track.addSublayer(dot)
            }
            root.addSublayer(track)
            tracks.append(track)
        }
    }

    /// The longest unbroken on-screen run of a route, as a path and its length.
    private func longestRun(of points: [GeoPoint], in mapView: MKMapView) -> (CGPath, CGFloat)? {
        var best: [CGPoint] = []
        var current: [CGPoint] = []
        for point in points {
            let projected = mapView.convert(point.mapCoordinate, toPointTo: self)
            if let last = current.last, abs(projected.x - last.x) >= bounds.width / 2 {
                if length(of: current) > length(of: best) { best = current }
                current = []
            }
            current.append(projected)
        }
        if length(of: current) > length(of: best) { best = current }
        guard best.count > 1 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: best)
        return (path, length(of: best))
    }

    private func length(of points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + hypot($1.1.x - $1.0.x, $1.1.y - $1.0.y) }
    }
}

/// Hosts the map and the flow layer, and shows a crosshair while placing.
final class NetworkMapContainerView: NSView {
    let mapView = MKMapView()
    let flowView = FlowOverlayView()
    var appearanceChanged: (() -> Void)?
    var sizeChanged: (() -> Void)?
    var showsPlacementCursor = false {
        didSet { if showsPlacementCursor != oldValue { window?.invalidateCursorRects(for: self) } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [mapView, flowView] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        appearanceChanged?()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { sizeChanged?() }
    }

    override func resetCursorRects() {
        if showsPlacementCursor { addCursorRect(bounds, cursor: .crosshair) }
    }
}

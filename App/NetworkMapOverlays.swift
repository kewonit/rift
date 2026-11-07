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

/// The whole cable network, drawn as one faint overlay. Approximate cables are
/// dashed, like ferry lines in Apple Maps.
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

/// The cable network is quiet background; routes in use are bold.
enum NetworkMapPalette {
    static func resolved(_ color: NSColor, alpha: CGFloat, in appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = NSColor(cgColor: color.withAlphaComponent(alpha).cgColor) ?? color
        }
        return result
    }

    static func cable(estimated: Bool, style: NetworkMapStyle, appearance: NSAppearance) -> NSColor {
        let base: NSColor = style == .satellite ? .white : .systemTeal
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let strength: CGFloat = style == .satellite || dark ? 0.32 : 0.42
        return resolved(base, alpha: estimated ? strength * 0.6 : strength, in: appearance)
    }

    static func cableWidth(estimated: Bool) -> CGFloat { estimated ? 0.8 : 1 }

    static func route(dimmed: Bool, appearance: NSAppearance) -> NSColor {
        resolved(.controlAccentColor, alpha: dimmed ? 0.22 : 0.95, in: appearance)
    }

    /// Routes are accent blue, which sinks into the blue of the light map, so
    /// there they get a light edge. Dark and satellite maps don't need one.
    static func routeOutline(dimmed: Bool, style: NetworkMapStyle, appearance: NSAppearance) -> NSColor? {
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        guard !dark, style == .standard else { return nil }
        return resolved(.white, alpha: dimmed ? 0.25 : 0.9, in: appearance)
    }

    static let routeOutlineWidth: CGFloat = 2
    static func routeWidth(isCable: Bool) -> CGFloat { isCable ? 3 : 2 }
    static let landDash: [NSNumber] = [4, 4]
}

/// A route line with an optional edge drawn underneath it.
final class RoutePolylineRenderer: MKPolylineRenderer {
    var outlineColor: NSColor?

    override func draw(_ mapRect: MKMapRect, zoomScale: MKZoomScale, in context: CGContext) {
        if let outlineColor {
            if path == nil { createPath() }
            if let path {
                context.saveGState()
                context.addPath(path)
                context.setStrokeColor(outlineColor.cgColor)
                context.setLineWidth((lineWidth + NetworkMapPalette.routeOutlineWidth) / zoomScale)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.strokePath()
                context.restoreGState()
            }
        }
        super.draw(mapRect, zoomScale: zoomScale, in: context)
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

    private static let dotsPerRoute = 2
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
        let ring = NetworkMapPalette.resolved(.controlAccentColor, alpha: 1, in: effectiveAppearance).cgColor
        for flow in flows {
            guard let (path, length) = longestRun(of: flow.points, in: mapView), length > 40 else { continue }
            let duration = min(max(Double(length) / Self.pointsPerSecond, 2.5), 9)
            let track = CALayer()
            track.frame = bounds
            for index in 0..<Self.dotsPerRoute {
                let dot = CALayer()
                dot.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
                dot.cornerRadius = 3.5
                dot.backgroundColor = fill
                dot.borderColor = ring
                dot.borderWidth = 1.5
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

    override func resetCursorRects() {
        if showsPlacementCursor { addCursorRect(bounds, cursor: .crosshair) }
    }
}

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

/// The whole cable network, drawn as one overlay. Estimated routes are dashed,
/// like ferry lines in Apple Maps.
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
    let destination: MapDestination
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(destination: MapDestination, point: GeoPoint) {
        self.destination = destination
        coordinate = point.mapCoordinate
        title = destination.name
        subtitle = destination.summary
    }
}

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
        return resolved(base, alpha: estimated ? 0.45 : 0.7, in: appearance)
    }

    static func route(dimmed: Bool, appearance: NSAppearance) -> NSColor {
        resolved(.controlAccentColor, alpha: dimmed ? 0.3 : 0.95, in: appearance)
    }
}

/// Small dots that travel along each highlighted route. Core Animation runs the
/// motion on the GPU; the map only re-projects paths when the view moves.
final class FlowOverlayView: NSView {
    struct Flow: Equatable {
        let id: String
        let points: [GeoPoint]
        let dimmed: Bool
    }

    private static let spacing: CGFloat = 14
    private var flows: [Flow] = []
    private var layers: [String: CAShapeLayer] = [:]
    var animates = true {
        didSet { if animates != oldValue { applyAnimations() } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setFlows(_ newFlows: [Flow], mapView: MKMapView) {
        guard newFlows != flows else { return }
        let keep = Set(newFlows.map(\.id))
        for (id, shape) in layers where !keep.contains(id) {
            shape.removeFromSuperlayer()
            layers[id] = nil
        }
        for flow in newFlows where layers[flow.id] == nil {
            let shape = CAShapeLayer()
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineWidth = 3.2
            shape.lineDashPattern = [0.01, NSNumber(value: Double(Self.spacing))]
            layer?.addSublayer(shape)
            layers[flow.id] = shape
        }
        flows = newFlows
        for flow in flows {
            layers[flow.id]?.strokeColor = NSColor.white.withAlphaComponent(flow.dimmed ? 0.35 : 0.95).cgColor
            layers[flow.id]?.shadowColor = NSColor.black.cgColor
            layers[flow.id]?.shadowOpacity = flow.dimmed ? 0 : 0.25
            layers[flow.id]?.shadowRadius = 1.5
            layers[flow.id]?.shadowOffset = .zero
        }
        reproject(using: mapView)
        applyAnimations()
    }

    func reproject(using mapView: MKMapView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for flow in flows {
            layers[flow.id]?.frame = bounds
            layers[flow.id]?.path = path(for: flow.points, mapView: mapView)
        }
        CATransaction.commit()
    }

    private func path(for points: [GeoPoint], mapView: MKMapView) -> CGPath {
        let path = CGMutablePath()
        var previous: CGPoint?
        for point in points {
            let projected = mapView.convert(point.mapCoordinate, toPointTo: self)
            if let previous, abs(projected.x - previous.x) < bounds.width / 2 {
                path.addLine(to: projected)
            } else {
                path.move(to: projected)
            }
            previous = projected
        }
        return path
    }

    private func applyAnimations() {
        for shape in layers.values {
            shape.removeAnimation(forKey: "flow")
            shape.isHidden = !animates
            guard animates else { continue }
            let animation = CABasicAnimation(keyPath: "lineDashPhase")
            animation.fromValue = Self.spacing
            animation.toValue = 0
            animation.duration = 0.9
            animation.repeatCount = .infinity
            shape.add(animation, forKey: "flow")
        }
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

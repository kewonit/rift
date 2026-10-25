import AppKit
import MapKit
import RiftControl
import SwiftUI

/// Apple Maps with the undersea cable network, the user's location, and the
/// estimated paths their connections take.
struct NetworkMapView: NSViewRepresentable {
    let resources: NetworkMapResources?
    let destinations: [MapDestination]
    let origin: CoarseMapOrigin?
    let isPlacingOrigin: Bool
    let highlightedCountries: Set<String>
    let style: NetworkMapStyle
    let animatesFlow: Bool
    let reduceMotion: Bool
    let fitRequest: Int
    let placeOrigin: (CoarseMapCoordinate) -> Void
    let selectCountry: (String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NetworkMapContainerView {
        let container = NetworkMapContainerView()
        let mapView = container.mapView
        mapView.delegate = context.coordinator
        mapView.preferredConfiguration = style.configuration
        mapView.isRotateEnabled = false
        mapView.isPitchEnabled = false
        mapView.showsCompass = false
        mapView.showsZoomControls = true
        mapView.showsScale = false
        mapView.setAccessibilityLabel("Map of undersea cables and where connections go")
        let world = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 20, longitude: 10),
            span: MKCoordinateSpan(latitudeDelta: 130, longitudeDelta: 300)
        )
        mapView.setRegion(mapView.regionThatFits(world), animated: false)
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        click.delegate = context.coordinator
        mapView.addGestureRecognizer(click)
        context.coordinator.container = container
        container.appearanceChanged = { [weak coordinator = context.coordinator] in
            coordinator?.refreshStyle()
        }
        return container
    }

    func updateNSView(_ container: NetworkMapContainerView, context: Context) {
        context.coordinator.update(with: self)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        weak var container: NetworkMapContainerView?
        private var parent: NetworkMapView?
        private var networkOverlays: [CableNetworkOverlay] = []
        private var routeOverlays: [RouteLegPolyline] = []
        private var destinationAnnotations: [DestinationAnnotation] = []
        private var originAnnotation: OriginAnnotation?
        private var shownDestinations: [MapDestination] = []
        private var shownHighlight: Set<String> = []
        private var shownStyle: NetworkMapStyle?
        private var shownOrigin: CoarseMapOrigin??
        private var shownFitRequest = 0
        private var fittedOrigin: CoarseMapOrigin?
        private var updatingSelection = false

        private var mapView: MKMapView? { container?.mapView }

        func update(with view: NetworkMapView) {
            parent = view
            guard let container, let mapView else { return }
            container.showsPlacementCursor = view.isPlacingOrigin
            if shownStyle != view.style {
                shownStyle = view.style
                mapView.preferredConfiguration = view.style.configuration
                refreshStyle()
            }
            if networkOverlays.isEmpty, let resources = view.resources {
                networkOverlays = [
                    CableNetworkOverlay.make(paths: resources.estimatedRoutes, estimated: true),
                    CableNetworkOverlay.make(paths: resources.mappedCables, estimated: false),
                ]
                mapView.addOverlays(networkOverlays, level: .aboveRoads)
            }
            if shownOrigin != .some(view.origin) {
                updateOrigin(view.origin, in: mapView)
            }
            if shownDestinations != view.destinations || shownHighlight != view.highlightedCountries {
                let highlightChanged = shownHighlight != view.highlightedCountries
                shownDestinations = view.destinations
                shownHighlight = view.highlightedCountries
                rebuildRoutes(in: mapView)
                if highlightChanged, !view.highlightedCountries.isEmpty {
                    fit(countries: view.highlightedCountries, in: mapView)
                } else if fittedOrigin != view.origin, view.origin != nil, !view.destinations.isEmpty {
                    fittedOrigin = view.origin
                    fit(countries: [], in: mapView)
                }
            }
            if shownFitRequest != view.fitRequest {
                shownFitRequest = view.fitRequest
                fit(countries: view.highlightedCountries, in: mapView)
            }
            container.flowView.animates = view.animatesFlow
        }

        func refreshStyle() {
            guard let mapView else { return }
            let overlays = mapView.overlays
            mapView.removeOverlays(overlays)
            mapView.addOverlays(networkOverlays, level: .aboveRoads)
            mapView.addOverlays(routeOverlays, level: .aboveLabels)
        }

        private func updateOrigin(_ origin: CoarseMapOrigin?, in mapView: MKMapView) {
            let wasSet = shownOrigin.flatMap { $0 } != nil
            shownOrigin = .some(origin)
            if let originAnnotation { mapView.removeAnnotation(originAnnotation) }
            originAnnotation = nil
            guard let origin else { return }
            let annotation = OriginAnnotation(coordinate: origin.mapCoordinate)
            originAnnotation = annotation
            mapView.addAnnotation(annotation)
            if !wasSet {
                let region = MKCoordinateRegion(
                    center: origin.mapCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 70, longitudeDelta: 120)
                )
                mapView.setRegion(mapView.regionThatFits(region), animated: false)
            }
        }

        private func rebuildRoutes(in mapView: MKMapView) {
            mapView.removeOverlays(routeOverlays)
            mapView.removeAnnotations(destinationAnnotations)
            routeOverlays = []
            destinationAnnotations = []
            var flows: [FlowOverlayView.Flow] = []
            for destination in shownDestinations {
                guard let point = destination.route.destination else { continue }
                destinationAnnotations.append(DestinationAnnotation(destination: destination, point: point))
                // Blocked connections never leave the Mac, so they get a marker but no path.
                guard !destination.activity.allBlocked,
                      case .undersea(let legs, _) = destination.route else { continue }
                var flowPoints: [GeoPoint] = []
                for leg in legs {
                    let isCable = if case .cable = leg.kind { true } else { false }
                    for part in NetworkMapGeometry.splitAtAntimeridian(leg.points) {
                        routeOverlays.append(RouteLegPolyline.make(part, countryCode: destination.countryCode, isCable: isCable))
                    }
                    flowPoints.append(contentsOf: leg.points)
                }
                flows.append(FlowOverlayView.Flow(
                    id: destination.countryCode,
                    points: flowPoints,
                    dimmed: isDimmed(destination.countryCode)
                ))
            }
            mapView.addOverlays(routeOverlays, level: .aboveLabels)
            mapView.addAnnotations(destinationAnnotations)
            container?.flowView.setFlows(flows, mapView: mapView)
            syncSelection(in: mapView)
        }

        private func isDimmed(_ countryCode: String) -> Bool {
            !shownHighlight.isEmpty && !shownHighlight.contains(countryCode)
        }

        private func syncSelection(in mapView: MKMapView) {
            updatingSelection = true
            defer { updatingSelection = false }
            let selected = destinationAnnotations.first {
                shownHighlight.count == 1 && shownHighlight.contains($0.destination.countryCode)
            }
            if let selected {
                mapView.selectAnnotation(selected, animated: false)
            } else {
                for annotation in mapView.selectedAnnotations { mapView.deselectAnnotation(annotation, animated: false) }
            }
        }

        /// Frames the origin and the chosen routes, measuring longitude around the
        /// origin so a view never wraps the long way around the world.
        private func fit(countries: Set<String>, in mapView: MKMapView) {
            var points: [CLLocationCoordinate2D] = originAnnotation.map { [$0.coordinate] } ?? []
            for destination in shownDestinations
            where countries.isEmpty || countries.contains(destination.countryCode) {
                if let point = destination.route.destination { points.append(point.mapCoordinate) }
                if !destination.activity.allBlocked, case .undersea(let legs, _) = destination.route {
                    points.append(contentsOf: legs.flatMap(\.points).map(\.mapCoordinate))
                }
            }
            guard let reference = points.first?.longitude, points.count > 1 else { return }
            let longitudes = points.map { reference + NetworkMapGeometry.wrapLongitude($0.longitude - reference) }
            let latitudes = points.map(\.latitude)
            guard let west = longitudes.min(), let east = longitudes.max(),
                  let south = latitudes.min(), let north = latitudes.max() else { return }
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: (south + north) / 2,
                    longitude: NetworkMapGeometry.wrapLongitude((west + east) / 2)
                ),
                span: MKCoordinateSpan(
                    latitudeDelta: min(150, max(12, (north - south) * 1.35)),
                    longitudeDelta: min(340, max(18, (east - west) * 1.25))
                )
            )
            mapView.setRegion(mapView.regionThatFits(region), animated: parent?.reduceMotion == false)
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            let appearance = mapView.effectiveAppearance
            let style = parent?.style ?? .standard
            if let network = overlay as? CableNetworkOverlay {
                let renderer = MKMultiPolylineRenderer(multiPolyline: network)
                renderer.strokeColor = NetworkMapPalette.cable(estimated: network.isEstimated, style: style, appearance: appearance)
                renderer.lineWidth = network.isEstimated ? 1.1 : 1.4
                renderer.lineCap = .round
                renderer.lineJoin = .round
                if network.isEstimated { renderer.lineDashPattern = [5, 4] }
                return renderer
            }
            if let leg = overlay as? RouteLegPolyline {
                let renderer = MKPolylineRenderer(polyline: leg)
                renderer.strokeColor = NetworkMapPalette.route(dimmed: isDimmed(leg.countryCode), appearance: appearance)
                renderer.lineWidth = leg.isCable ? 3.2 : 2
                renderer.lineCap = .round
                renderer.lineJoin = .round
                if !leg.isCable { renderer.lineDashPattern = [1, 5] }
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is OriginAnnotation {
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "origin") as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "origin")
                view.annotation = annotation
                view.glyphImage = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)
                view.markerTintColor = .systemIndigo
                view.titleVisibility = .visible
                view.displayPriority = .required
                view.canShowCallout = false
                return view
            }
            guard let destination = annotation as? DestinationAnnotation else { return nil }
            let view = (mapView.dequeueReusableAnnotationView(withIdentifier: "destination") as? MKMarkerAnnotationView)
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "destination")
            view.annotation = annotation
            let activity = destination.destination.activity
            if activity.allBlocked {
                view.glyphImage = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
                view.glyphText = nil
                view.markerTintColor = .systemRed
            } else {
                view.glyphImage = nil
                view.glyphText = activity.connections > 99 ? "99+" : String(activity.connections)
                view.markerTintColor = .controlAccentColor
            }
            view.alphaValue = isDimmed(activity.countryCode) ? 0.55 : 1
            view.titleVisibility = .adaptive
            view.subtitleVisibility = .hidden
            view.displayPriority = .defaultHigh
            view.canShowCallout = true
            return view
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            guard !updatingSelection else { return }
            if let destination = view.annotation as? DestinationAnnotation {
                parent?.selectCountry(destination.destination.countryCode)
            }
        }

        func mapView(_ mapView: MKMapView, didDeselect view: MKAnnotationView) {
            guard !updatingSelection, view.annotation is DestinationAnnotation else { return }
            Task { @MainActor [weak self, weak mapView] in
                guard let self, let mapView,
                      !mapView.selectedAnnotations.contains(where: { $0 is DestinationAnnotation }) else { return }
                parent?.selectCountry(nil)
            }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            container?.flowView.reproject(using: mapView)
        }

        // MARK: Placing the user's location

        func gestureRecognizerShouldBegin(_ gestureRecognizer: NSGestureRecognizer) -> Bool {
            parent?.isPlacingOrigin == true
        }

        @objc func handleClick(_ recognizer: NSClickGestureRecognizer) {
            guard let mapView, parent?.isPlacingOrigin == true else { return }
            let coordinate = mapView.convert(recognizer.location(in: mapView), toCoordinateFrom: mapView)
            guard let coarse = try? CoarseMapCoordinate(
                latitude: coordinate.latitude, longitude: coordinate.longitude
            ) else { return }
            parent?.placeOrigin(coarse)
        }
    }
}

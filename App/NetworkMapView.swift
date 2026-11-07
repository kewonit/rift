import AppKit
import MapKit
import RiftControl
import SwiftUI

/// Apple Maps with the faint undersea cable network, the user's location, and
/// bold estimated paths for the connections in view.
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
        mapView.showsZoomControls = false
        mapView.showsScale = false
        // Rift never shows buildings; skipping them saves tile data when zoomed in.
        mapView.showsBuildings = false
        mapView.register(DestinationMarkerView.self, forAnnotationViewWithReuseIdentifier: DestinationMarkerView.reuseIdentifier)
        mapView.register(OriginMarkerView.self, forAnnotationViewWithReuseIdentifier: OriginMarkerView.reuseIdentifier)
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
        container.sizeChanged = { [weak coordinator = context.coordinator] in
            coordinator?.paneResized()
        }
        return container
    }

    func updateNSView(_ container: NetworkMapContainerView, context: Context) {
        context.coordinator.update(with: self)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate, NSGestureRecognizerDelegate {
        /// What decides a route's geometry. Counts can change without touching it.
        struct RouteKey: Equatable {
            let route: CableRoute
            let allBlocked: Bool
        }

        private struct Entry {
            let key: RouteKey
            let legs: [RouteLegPolyline]
            let annotation: DestinationAnnotation?
        }

        weak var container: NetworkMapContainerView?
        private var parent: NetworkMapView?
        private var networkOverlays: [CableNetworkOverlay] = []
        private var entries: [String: Entry] = [:]
        private var originAnnotation: OriginAnnotation?
        private var shownDestinations: [MapDestination] = []
        private var shownHighlight: Set<String> = []
        private var shownStyle: NetworkMapStyle?
        private var shownOrigin: CoarseMapOrigin??
        private var shownFitRequest = 0
        private var fittedOrigin: CoarseMapOrigin?
        /// What the map is fitted to, until the user moves it.
        private var fittedCountries: Set<String>?
        private var fitting = false
        private var resizing = false
        private var refitTask: Task<Void, Never>?
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
            let highlightChanged = shownHighlight != view.highlightedCountries
            if shownDestinations != view.destinations || highlightChanged {
                shownDestinations = view.destinations
                shownHighlight = view.highlightedCountries
                syncRoutes(in: mapView, highlightChanged: highlightChanged)
                if highlightChanged, !view.highlightedCountries.isEmpty {
                    fit(countries: view.highlightedCountries, in: mapView, animated: true)
                } else if highlightChanged, fittedCountries != nil {
                    fit(countries: [], in: mapView, animated: true)
                } else if fittedOrigin != view.origin, view.origin != nil, !view.destinations.isEmpty {
                    // The first fit jumps straight there: animating from the
                    // world view loads tiles for every zoom level in between.
                    fittedOrigin = view.origin
                    fit(countries: view.highlightedCountries, in: mapView, animated: false)
                }
            }
            if shownFitRequest != view.fitRequest {
                shownFitRequest = view.fitRequest
                fit(countries: view.highlightedCountries, in: mapView, animated: true)
            }
            container.flowView.animates = view.animatesFlow
        }

        func refreshStyle() {
            guard let mapView else { return }
            mapView.removeOverlays(mapView.overlays)
            mapView.addOverlays(networkOverlays, level: .aboveRoads)
            mapView.addOverlays(entries.values.flatMap(\.legs), level: .aboveLabels)
            refreshEmphasis(in: mapView)
            if let originAnnotation {
                (mapView.view(for: originAnnotation) as? OriginMarkerView)?.style = parent?.style ?? .standard
            }
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

        /// Adds, removes or replaces only the routes whose geometry changed, and
        /// updates counts and dimming in place for the rest.
        private func syncRoutes(in mapView: MKMapView, highlightChanged: Bool) {
            var byCountry: [String: MapDestination] = [:]
            for destination in shownDestinations where destination.route.destination != nil {
                byCountry[destination.countryCode] = destination
            }
            let diff = KeyedDiff(
                old: entries.mapValues(\.key),
                new: byCountry.mapValues { RouteKey(route: $0.route, allBlocked: $0.activity.allBlocked) }
            )
            for code in diff.removed + diff.changed {
                guard let entry = entries.removeValue(forKey: code) else { continue }
                mapView.removeOverlays(entry.legs)
                if let annotation = entry.annotation { mapView.removeAnnotation(annotation) }
            }
            var addedLegs: [RouteLegPolyline] = []
            var addedAnnotations: [DestinationAnnotation] = []
            for code in diff.inserted + diff.changed {
                guard let destination = byCountry[code], let point = destination.route.destination else { continue }
                let annotation = DestinationAnnotation(destination: destination, point: point)
                var legs: [RouteLegPolyline] = []
                // Blocked connections never leave the Mac, so they get a marker but no path.
                if !destination.activity.allBlocked, case .undersea(let routeLegs, _) = destination.route {
                    for leg in routeLegs {
                        let isCable = if case .cable = leg.kind { true } else { false }
                        for part in NetworkMapGeometry.splitAtAntimeridian(leg.points) {
                            legs.append(RouteLegPolyline.make(RouteSmoothing.smoothed(part), countryCode: code, isCable: isCable))
                        }
                    }
                }
                entries[code] = Entry(
                    key: RouteKey(route: destination.route, allBlocked: destination.activity.allBlocked),
                    legs: legs, annotation: annotation
                )
                addedLegs += legs
                addedAnnotations.append(annotation)
            }
            for code in diff.unchanged {
                guard let destination = byCountry[code], let annotation = entries[code]?.annotation else { continue }
                annotation.update(destination)
                (mapView.view(for: annotation) as? DestinationMarkerView)?
                    .configure(destination, dimmed: isDimmed(code), style: parent?.style ?? .standard)
            }
            if !addedLegs.isEmpty { mapView.addOverlays(addedLegs, level: .aboveLabels) }
            if !addedAnnotations.isEmpty { mapView.addAnnotations(addedAnnotations) }
            if highlightChanged { refreshEmphasis(in: mapView) }
            container?.flowView.setFlows(flows(), mapView: mapView)
            syncSelection(in: mapView)
        }

        /// Routes whose dots move: the selected ones, or the four busiest.
        private func flows() -> [FlowOverlayView.Flow] {
            let candidates = shownDestinations.filter { !$0.activity.allBlocked && entries[$0.countryCode]?.legs.isEmpty == false }
            let focused = shownHighlight.isEmpty
                ? Array(candidates.sorted { $0.activity.connections > $1.activity.connections }.prefix(4))
                : candidates.filter { shownHighlight.contains($0.countryCode) }
            return focused.compactMap { destination in
                guard case .undersea(let legs, _) = destination.route else { return nil }
                let points = legs.flatMap { leg in
                    NetworkMapGeometry.splitAtAntimeridian(leg.points).flatMap(RouteSmoothing.smoothed)
                }
                return FlowOverlayView.Flow(id: destination.countryCode, points: points)
            }
        }

        private func refreshEmphasis(in mapView: MKMapView) {
            let appearance = mapView.effectiveAppearance
            let style = parent?.style ?? .standard
            for (code, entry) in entries {
                let dimmed = isDimmed(code)
                for leg in entry.legs {
                    guard let renderer = mapView.renderer(for: leg) as? MKPolylineRenderer else { continue }
                    renderer.strokeColor = NetworkMapPalette.route(
                        isCable: leg.isCable, dimmed: dimmed, style: style, appearance: appearance
                    )
                    renderer.setNeedsDisplay()
                }
                if let annotation = entry.annotation {
                    (mapView.view(for: annotation) as? DestinationMarkerView)?
                        .configure(annotation.destination, dimmed: dimmed, style: style)
                }
            }
        }

        private func isDimmed(_ countryCode: String) -> Bool {
            !shownHighlight.isEmpty && !shownHighlight.contains(countryCode)
        }

        private func syncSelection(in mapView: MKMapView) {
            updatingSelection = true
            defer { updatingSelection = false }
            let selected = shownHighlight.count == 1
                ? shownHighlight.first.flatMap { entries[$0]?.annotation } : nil
            if let selected {
                if !mapView.selectedAnnotations.contains(where: { $0 === selected }) {
                    mapView.selectAnnotation(selected, animated: false)
                }
            } else {
                for annotation in mapView.selectedAnnotations { mapView.deselectAnnotation(annotation, animated: false) }
            }
        }

        /// Frames the origin and the chosen routes, measuring longitude around the
        /// origin so a view never wraps the long way around the world.
        private func fit(countries: Set<String>, in mapView: MKMapView, animated: Bool) {
            let origin = originAnnotation?.coordinate
            var points: [CLLocationCoordinate2D] = origin.map { [$0] } ?? []
            for destination in shownDestinations
            where countries.isEmpty || countries.contains(destination.countryCode) {
                if let point = destination.route.destination { points.append(point.mapCoordinate) }
                // A country in focus shows its whole route. The overview only
                // needs the ends, or waypoints would decide the framing.
                if !countries.isEmpty, !destination.activity.allBlocked, case .undersea(let legs, _) = destination.route {
                    points.append(contentsOf: legs.flatMap(\.points).map(\.mapCoordinate))
                }
            }
            guard points.count > 1,
                  let window = MapFraming.longitudeWindow(points.map(\.longitude), keeping: origin?.longitude)
            else { return }
            let latitudes = points.filter { window.contains($0.longitude) }.map(\.latitude)
            guard let south = latitudes.min(), let north = latitudes.max() else { return }
            // The map runs under the toolbar, so keep the routes below it.
            let covered = mapView.safeAreaInsets.top / max(mapView.bounds.height, 1)
            let wanted = max(12, (north - south) * 1.2) / (1 - covered)
            // Degrees of latitude the pane shows per degree of longitude. Mercator
            // stretches away from the equator, so it's less than the aspect ratio.
            let shape = mapView.bounds.height / max(mapView.bounds.width, 1) * 0.8
            // A tall route zooms the map out, as far as MapKit can go.
            let longitudeDelta = min(
                MapFraming.widest, max(18, window.span * MapFraming.margin, wanted / max(shape, 0.01))
            )
            let tallest = longitudeDelta * shape
            let latitudeDelta = min(tallest, wanted)
            // When everything can't fit, stay where most of the destinations are.
            let middle = wanted > tallest
                ? latitudes.reduce(0, +) / Double(latitudes.count)
                : (south + north) / 2
            let region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(
                    latitude: middle + latitudeDelta * covered / 2,
                    longitude: window.centre
                ),
                span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
            )
            fittedCountries = countries
            fitting = true
            mapView.setRegion(mapView.regionThatFits(region), animated: animated && parent?.reduceMotion == false)
        }

        /// The pane changed size, so fit again unless the user has moved the map.
        func paneResized() {
            guard fittedCountries != nil else { return }
            resizing = true
            refitTask?.cancel()
            refitTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.resizing = false
                guard let mapView = self.mapView, let countries = self.fittedCountries else { return }
                self.fit(countries: countries, in: mapView, animated: true)
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            let appearance = mapView.effectiveAppearance
            let style = parent?.style ?? .standard
            if let network = overlay as? CableNetworkOverlay {
                let renderer = MKMultiPolylineRenderer(multiPolyline: network)
                renderer.strokeColor = NetworkMapPalette.cable(estimated: network.isEstimated, style: style, appearance: appearance)
                renderer.lineWidth = NetworkMapPalette.cableWidth
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            if let leg = overlay as? RouteLegPolyline {
                let renderer = MKPolylineRenderer(polyline: leg)
                renderer.strokeColor = NetworkMapPalette.route(
                    isCable: leg.isCable, dimmed: isDimmed(leg.countryCode), style: style, appearance: appearance
                )
                renderer.lineWidth = NetworkMapPalette.routeWidth(isCable: leg.isCable)
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is OriginAnnotation {
                let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: OriginMarkerView.reuseIdentifier, for: annotation
                )
                (view as? OriginMarkerView)?.style = parent?.style ?? .standard
                return view
            }
            guard let destination = annotation as? DestinationAnnotation,
                  let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: DestinationMarkerView.reuseIdentifier, for: annotation
                  ) as? DestinationMarkerView else { return nil }
            view.configure(
                destination.destination,
                dimmed: isDimmed(destination.destination.countryCode),
                style: parent?.style ?? .standard
            )
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

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            if !fitting, !resizing { fittedCountries = nil }
            container?.flowView.regionWillChange()
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            fitting = false
            container?.flowView.regionDidChange()
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

private extension MKMapRect {
    /// The map rectangle covering a region, wrapping across the antimeridian.
    static func from(_ region: MKCoordinateRegion) -> MKMapRect {
        let topLeft = MKMapPoint(CLLocationCoordinate2D(
            latitude: min(85, region.center.latitude + region.span.latitudeDelta / 2),
            longitude: NetworkMapGeometry.wrapLongitude(region.center.longitude - region.span.longitudeDelta / 2)
        ))
        let bottomRight = MKMapPoint(CLLocationCoordinate2D(
            latitude: max(-85, region.center.latitude - region.span.latitudeDelta / 2),
            longitude: NetworkMapGeometry.wrapLongitude(region.center.longitude + region.span.longitudeDelta / 2)
        ))
        var width = bottomRight.x - topLeft.x
        if width < 0 { width += MKMapSize.world.width }
        return MKMapRect(x: topLeft.x, y: topLeft.y, width: width, height: bottomRight.y - topLeft.y)
    }
}

enum MapFraming {
    /// MapKit shows about half the world across at most, and asking for much
    /// more lands the map on the far side of the globe.
    static let widest: Double = 170
    static let margin = 1.15

    struct Window {
        let west: Double
        let span: Double

        var centre: Double { NetworkMapGeometry.wrapLongitude(west + span / 2) }

        func contains(_ longitude: Double) -> Bool {
            let offset = (longitude - west).truncatingRemainder(dividingBy: 360)
            return (offset < 0 ? offset + 360 : offset) <= span
        }
    }

    /// The stretch of longitude to show. It's the narrowest one holding every
    /// point, which on a circle means everything but the widest empty gap. When
    /// that's too wide to show, it's the window holding the most points that
    /// still includes `anchor`.
    static func longitudeWindow(_ longitudes: [Double], keeping anchor: Double?) -> Window? {
        let sorted = longitudes.map(NetworkMapGeometry.wrapLongitude).sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        var gap = first + 360 - last
        var west = first
        for (start, end) in zip(sorted, sorted.dropFirst()) where end - start > gap {
            gap = end - start
            west = end
        }
        let span = widest / margin
        guard 360 - gap > span else { return Window(west: west, span: 360 - gap) }
        let candidates = sorted
            .flatMap { [Window(west: $0, span: span), Window(west: $0 - span, span: span)] }
            .filter { window in anchor.map(window.contains) ?? true }
        return candidates.max { left, right in
            sorted.filter(left.contains).count < sorted.filter(right.contains).count
        }
    }
}

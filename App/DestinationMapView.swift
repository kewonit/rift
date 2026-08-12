import RiftControl
import AppKit
import MapKit
import SwiftUI

struct CoarseMapOrigin: Hashable {
    let coordinate: CoarseMapCoordinate
}

struct DestinationMapPoint: Identifiable, Hashable {
    let id: String
    let latitude: Double
    let longitude: Double
    let title: String
    let count: Int

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct DestinationMapView: NSViewRepresentable {
    let points: [DestinationMapPoint]
    let linkedPointIDs: Set<String>
    let accessibilityValue: String
    @Binding var selectionID: String?
    @Binding var origin: CoarseMapOrigin?
    @Binding var isPlacingOrigin: Bool
    let reduceMotion: Bool
    let onReady: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        context.coordinator.update(from: self)
        map.delegate = context.coordinator
        map.showsUserLocation = false
        map.showsZoomControls = false
        map.pointOfInterestFilter = .excludingAll
        map.register(
            MKMarkerAnnotationView.self,
            forAnnotationViewWithReuseIdentifier: "destination"
        )
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.placeOrigin(_:))
        )
        click.isEnabled = isPlacingOrigin
        map.addGestureRecognizer(click)
        map.setAccessibilityLabel("Approximate destination locations")
        map.setAccessibilityValue(accessibilityValue)
        context.coordinator.map = map
        context.coordinator.placementRecognizer = click
        return map
    }

    static func dismantleNSView(_ map: MKMapView, coordinator: Coordinator) {
        map.delegate = nil
        if let recognizer = coordinator.placementRecognizer {
            map.removeGestureRecognizer(recognizer)
        }
        coordinator.placementRecognizer = nil
        coordinator.map = nil
        coordinator.detach()
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.update(from: self)
        map.setAccessibilityValue(accessibilityValue)
        context.coordinator.placementRecognizer?.isEnabled = isPlacingOrigin
        let signature = Self.signature(points: points, links: linkedPointIDs, origin: origin)
        if signature != context.coordinator.signature {
            context.coordinator.signature = signature
            rebuildMap(map)
        }
        synchronizeSelection(on: map)
    }

    private func rebuildMap(_ map: MKMapView) {
        map.removeOverlays(map.overlays)
        map.removeAnnotations(map.annotations.filter { !($0 is MKUserLocation) })
        let destinations = points.map(DestinationAnnotation.init)
        map.addAnnotations(destinations)
        var visibleCoordinates = destinations.map(\.coordinate)
        if let origin {
            let coordinate = CLLocationCoordinate2D(
                latitude: origin.coordinate.latitude,
                longitude: origin.coordinate.longitude
            )
            map.addAnnotation(OriginAnnotation(coordinate: coordinate))
            visibleCoordinates.append(coordinate)
            let pointsByID = Dictionary(uniqueKeysWithValues: points.map { ($0.id, $0) })
            let links = linkedPointIDs.compactMap { id -> MKGeodesicPolyline? in
                guard let point = pointsByID[id] else { return nil }
                var coordinates = [coordinate, point.coordinate]
                return MKGeodesicPolyline(coordinates: &coordinates, count: coordinates.count)
            }
            map.addOverlays(links, level: .aboveRoads)
        }
        if let region = Self.visibleRegion(for: visibleCoordinates) {
            map.setRegion(region, animated: false)
        }
    }

    private func synchronizeSelection(on map: MKMapView) {
        if let selectionID,
           let annotation = map.annotations.compactMap({ $0 as? DestinationAnnotation })
            .first(where: { $0.pointID == selectionID }),
           !map.selectedAnnotations.contains(where: { ($0 as? DestinationAnnotation) === annotation }) {
            map.selectAnnotation(annotation, animated: !reduceMotion)
        } else if selectionID == nil {
            map.selectedAnnotations.forEach { map.deselectAnnotation($0, animated: false) }
        }
    }

    private static func signature(
        points: [DestinationMapPoint],
        links: Set<String>,
        origin: CoarseMapOrigin?
    ) -> String {
        let pointValue = points.map {
            "\($0.id):\($0.latitude):\($0.longitude):\($0.title):\($0.count)"
        }.joined(separator: ";")
        let linkValue = links.sorted().joined(separator: ";")
        let originValue = origin.map {
            "\($0.coordinate.latitude):\($0.coordinate.longitude)"
        } ?? "none"
        return "\(pointValue)|\(linkValue)|\(originValue)"
    }

    private static func visibleRegion(
        for coordinates: [CLLocationCoordinate2D]
    ) -> MKCoordinateRegion? {
        let positions = coordinates.compactMap {
            try? MonitorMapPosition(latitude: $0.latitude, longitude: $0.longitude)
        }
        guard let viewport = MonitorMapGeometry.viewport(for: positions) else { return nil }
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(
                latitude: viewport.centerLatitude,
                longitude: viewport.centerLongitude
            ),
            span: MKCoordinateSpan(
                latitudeDelta: viewport.latitudeDelta,
                longitudeDelta: viewport.longitudeDelta
            )
        )
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var map: MKMapView?
        weak var placementRecognizer: NSClickGestureRecognizer?
        var signature = ""
        private var isPlacingOrigin = false
        private var reduceMotion = false
        private var setOrigin: ((CoarseMapOrigin) -> Void)?
        private var setPlacingOrigin: ((Bool) -> Void)?
        private var setSelection: ((String?) -> Void)?
        private var onReady: (() -> Void)?

        func update(from parent: DestinationMapView) {
            isPlacingOrigin = parent.isPlacingOrigin
            reduceMotion = parent.reduceMotion
            let origin = parent.$origin
            let placing = parent.$isPlacingOrigin
            let selection = parent.$selectionID
            setOrigin = { origin.wrappedValue = $0 }
            setPlacingOrigin = { placing.wrappedValue = $0 }
            setSelection = { selection.wrappedValue = $0 }
            onReady = parent.onReady
        }

        func detach() {
            isPlacingOrigin = false
            setOrigin = nil
            setPlacingOrigin = nil
            setSelection = nil
            onReady = nil
        }

        @objc func placeOrigin(_ recognizer: NSClickGestureRecognizer) {
            guard isPlacingOrigin, recognizer.state == .ended, let map else { return }
            let point = recognizer.location(in: map)
            let coordinate = map.convert(point, toCoordinateFrom: map)
            guard let coarse = try? CoarseMapCoordinate(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude
            ) else { return }
            setOrigin?(CoarseMapOrigin(coordinate: coarse))
            setPlacingOrigin?(false)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is OriginAnnotation {
                let view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "origin")
                view.markerTintColor = .labelColor
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.glyphImage = NSImage(
                    systemSymbolName: "laptopcomputer",
                    accessibilityDescription: "Approximate origin"
                )
                view.canShowCallout = true
                return view
            }
            if let cluster = annotation as? MKClusterAnnotation {
                let view = MKMarkerAnnotationView(annotation: cluster, reuseIdentifier: "cluster")
                view.markerTintColor = .systemIndigo
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.glyphText = String(cluster.memberAnnotations.count)
                view.canShowCallout = true
                return view
            }
            guard annotation is DestinationAnnotation,
                  let view = mapView.dequeueReusableAnnotationView(
                    withIdentifier: "destination", for: annotation
                  ) as? MKMarkerAnnotationView else { return nil }
            view.annotation = annotation
            view.clusteringIdentifier = "rift-destination"
            view.markerTintColor = .systemIndigo
            view.titleVisibility = .hidden
            view.subtitleVisibility = .hidden
            view.glyphImage = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
            view.canShowCallout = true
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = NSColor.systemIndigo.withAlphaComponent(0.48)
            renderer.lineWidth = 1.25
            return renderer
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                let coordinates = cluster.memberAnnotations.map(\.coordinate)
                if let region = DestinationMapView.visibleRegion(for: coordinates) {
                    mapView.setRegion(region, animated: !reduceMotion)
                }
                mapView.deselectAnnotation(cluster, animated: false)
            } else if let value = view.annotation as? DestinationAnnotation {
                setSelection?(value.pointID)
            }
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            guard fullyRendered else { return }
            signalReadyIfPossible()
        }

        func signalReadyIfPossible() {
            guard !didSignalReady,
                  let map,
                  map.annotations.contains(where: { $0 is DestinationAnnotation }) else { return }
            didSignalReady = true
            onReady?()
        }

        private var didSignalReady = false
    }
}

#if DEBUG
struct DestinationMapPreviewView: View {
    let points: [DestinationMapPoint]
    let linkedPointIDs: Set<String>
    let accessibilityValue: String
    @Binding var selectionID: String?
    @Binding var origin: CoarseMapOrigin?
    @Binding var isPlacingOrigin: Bool
    let onReady: () -> Void

    private var viewport: MonitorMapViewport {
        var positions = points.compactMap {
            try? MonitorMapPosition(latitude: $0.latitude, longitude: $0.longitude)
        }
        if let origin,
           let position = try? MonitorMapPosition(
                latitude: origin.coordinate.latitude,
                longitude: origin.coordinate.longitude
           ) {
            positions.append(position)
        }
        return MonitorMapGeometry.viewport(for: positions) ?? MonitorMapViewport(
            centerLatitude: 48,
            centerLongitude: 8,
            latitudeDelta: 28,
            longitudeDelta: 42
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let viewport = viewport
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.28, green: 0.70, blue: 0.91),
                        Color(red: 0.16, green: 0.58, blue: 0.83)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                Canvas { context, size in
                    drawBackdrop(in: &context, size: size)
                    drawLinks(in: &context, size: size, viewport: viewport)
                }
                ForEach(points) { point in
                    Button {
                        selectionID = point.id
                    } label: {
                        VStack(spacing: 3) {
                            Text(cityName(point.title))
                                .font(.caption2.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(.regularMaterial, in: Capsule())
                            Circle()
                                .fill(selectionID == point.id ? Color.accentColor : .white)
                                .frame(width: 14, height: 14)
                                .overlay(Circle().stroke(.black.opacity(0.18), lineWidth: 1))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(point.title), \(point.count) connection\(point.count == 1 ? "" : "s")"
                    )
                    .position(position(
                        latitude: point.latitude,
                        longitude: point.longitude,
                        viewport: viewport,
                        size: proxy.size
                    ))
                }
                if let origin {
                    Image(systemName: "laptopcomputer")
                        .foregroundStyle(.primary)
                        .padding(8)
                        .background(.regularMaterial, in: Circle())
                        .position(position(
                            latitude: origin.coordinate.latitude,
                            longitude: origin.coordinate.longitude,
                            viewport: viewport,
                            size: proxy.size
                        ))
                        .accessibilityLabel("Approximate origin")
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                placeOrigin(at: value.location, size: proxy.size, viewport: viewport)
            })
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approximate destination locations")
        .accessibilityValue(accessibilityValue)
        .onAppear(perform: onReady)
    }

    private func cityName(_ title: String) -> String {
        title.split(separator: ",", maxSplits: 1).first.map(String.init) ?? title
    }

    private func drawBackdrop(in context: inout GraphicsContext, size: CGSize) {
        var land = Path()
        land.move(to: CGPoint(x: size.width * 0.08, y: size.height * 0.12))
        land.addCurve(
            to: CGPoint(x: size.width * 0.96, y: size.height * 0.20),
            control1: CGPoint(x: size.width * 0.32, y: size.height * 0.02),
            control2: CGPoint(x: size.width * 0.68, y: size.height * 0.30)
        )
        land.addLine(to: CGPoint(x: size.width * 0.90, y: size.height * 0.90))
        land.addCurve(
            to: CGPoint(x: size.width * 0.12, y: size.height * 0.84),
            control1: CGPoint(x: size.width * 0.62, y: size.height * 0.72),
            control2: CGPoint(x: size.width * 0.30, y: size.height * 1.02)
        )
        land.closeSubpath()
        context.fill(land, with: .color(Color(red: 0.66, green: 0.82, blue: 0.51)))

        for fraction: CGFloat in [0.2, 0.4, 0.6, 0.8] {
            var vertical = Path()
            vertical.move(to: CGPoint(x: size.width * fraction, y: 0))
            vertical.addLine(to: CGPoint(x: size.width * fraction, y: size.height))
            context.stroke(vertical, with: .color(.white.opacity(0.14)), lineWidth: 0.5)
            var horizontal = Path()
            horizontal.move(to: CGPoint(x: 0, y: size.height * fraction))
            horizontal.addLine(to: CGPoint(x: size.width, y: size.height * fraction))
            context.stroke(horizontal, with: .color(.white.opacity(0.14)), lineWidth: 0.5)
        }
    }

    private func drawLinks(
        in context: inout GraphicsContext,
        size: CGSize,
        viewport: MonitorMapViewport
    ) {
        guard let origin else { return }
        let start = position(
            latitude: origin.coordinate.latitude,
            longitude: origin.coordinate.longitude,
            viewport: viewport,
            size: size
        )
        for point in points where linkedPointIDs.contains(point.id) {
            var path = Path()
            path.move(to: start)
            path.addLine(to: position(
                latitude: point.latitude,
                longitude: point.longitude,
                viewport: viewport,
                size: size
            ))
            context.stroke(path, with: .color(.indigo.opacity(0.46)), lineWidth: 1.25)
        }
    }

    private func placeOrigin(
        at location: CGPoint,
        size: CGSize,
        viewport: MonitorMapViewport
    ) {
        guard isPlacingOrigin, size.width > 0, size.height > 0 else { return }
        let latitude = viewport.centerLatitude
            - (Double(location.y / size.height) - 0.5) * viewport.latitudeDelta
        let longitude = viewport.centerLongitude
            + (Double(location.x / size.width) - 0.5) * viewport.longitudeDelta
        guard let coordinate = try? CoarseMapCoordinate(
            latitude: latitude,
            longitude: longitude
        ) else { return }
        origin = CoarseMapOrigin(coordinate: coordinate)
        isPlacingOrigin = false
    }

    private func position(
        latitude: Double,
        longitude: Double,
        viewport: MonitorMapViewport,
        size: CGSize
    ) -> CGPoint {
        var longitudeOffset = longitude - viewport.centerLongitude
        if longitudeOffset > 180 { longitudeOffset -= 360 }
        if longitudeOffset < -180 { longitudeOffset += 360 }
        let x = min(max(0.5 + longitudeOffset / viewport.longitudeDelta, 0.04), 0.96)
        let y = min(max(
            0.5 - (latitude - viewport.centerLatitude) / viewport.latitudeDelta,
            0.06
        ), 0.94)
        return CGPoint(x: size.width * CGFloat(x), y: size.height * CGFloat(y))
    }
}
#endif

@MainActor
private final class DestinationAnnotation: NSObject, MKAnnotation {
    let pointID: String
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let subtitle: String?

    init(_ point: DestinationMapPoint) {
        pointID = point.id
        coordinate = point.coordinate
        title = point.title
        subtitle = "\(point.count) connection\(point.count == 1 ? "" : "s")"
        super.init()
    }
}

@MainActor
private final class OriginAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String? = "Approximate origin"
    let subtitle: String? = "Chosen for display only"

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
        super.init()
    }
}

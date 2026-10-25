import MapKit
import RiftControl
import SwiftUI

struct CoarseMapOrigin: Hashable {
    let coordinate: CoarseMapCoordinate

    var mapCoordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }
}

/// The user's own map location. Rift never looks it up; the user places it on the map.
@MainActor
@Observable
final class MapOriginController {
    private static let defaultsKey = "liveMapOriginCoordinateV2"

    var origin: CoarseMapOrigin? {
        didSet { if persists { save() } }
    }
    var isPlacingManually = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let persists: Bool

    init(defaults: UserDefaults = .standard, persists: Bool = true) {
        self.defaults = defaults
        self.persists = persists
        guard persists,
              let stored = defaults.array(forKey: Self.defaultsKey) as? [Double],
              stored.count == 2,
              let coordinate = try? CoarseMapCoordinate(latitude: stored[0], longitude: stored[1])
        else { return }
        origin = CoarseMapOrigin(coordinate: coordinate)
    }

    func beginManualPlacement() { isPlacingManually = true }
    func cancelPlacement() { isPlacingManually = false }
    func clearOrigin() {
        isPlacingManually = false
        origin = nil
    }

    private func save() {
        if let origin {
            defaults.set(
                [origin.coordinate.latitude, origin.coordinate.longitude],
                forKey: Self.defaultsKey
            )
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }
}

struct OriginMapView: View {
    @Binding var origin: CoarseMapOrigin?
    @Binding var isPlacingOrigin: Bool
    let activityVisible: Bool
    let onReady: () -> Void
    @State private var cameraPosition: MapCameraPosition = .rect(.world)

    var body: some View {
        Group {
            if activityVisible {
                interactiveMap
            } else {
                Color(nsColor: .windowBackgroundColor).accessibilityHidden(true)
            }
        }
        .onAppear {
            if let origin { cameraPosition = .region(Self.region(around: origin)) }
            onReady()
        }
    }

    private var interactiveMap: some View {
        MapReader { proxy in
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom]) {
                if let origin {
                    Annotation("This Mac", coordinate: origin.mapCoordinate, anchor: .center) {
                        OriginMapMarker()
                    }
                }
            }
            .mapStyle(.standard(
                elevation: .flat,
                emphasis: .automatic,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            ))
            .mapControlVisibility(.hidden)
            .simultaneousGesture(placementGesture(proxy: proxy))
        }
        .overlay(alignment: .topTrailing) {
            if isPlacingOrigin {
                Label("Click the map to place this Mac", systemImage: "location.circle.fill")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.regularMaterial, in: Capsule())
                    .padding(10)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Map")
        .accessibilityValue(origin == nil ? "No location set" : "Showing your chosen location")
        .onExitCommand { isPlacingOrigin = false }
    }

    private func placementGesture(proxy: MapProxy) -> some Gesture {
        SpatialTapGesture().onEnded { value in
            guard isPlacingOrigin,
                  let coordinate = proxy.convert(value.location, from: .local),
                  let coarse = try? CoarseMapCoordinate(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude
                  ) else { return }
            origin = CoarseMapOrigin(coordinate: coarse)
            isPlacingOrigin = false
        }
    }

    private static func region(around origin: CoarseMapOrigin) -> MKCoordinateRegion {
        MKCoordinateRegion(
            center: origin.mapCoordinate,
            span: MKCoordinateSpan(latitudeDelta: 50, longitudeDelta: 70)
        )
    }
}

private struct OriginMapMarker: View {
    var body: some View {
        Image(systemName: "laptopcomputer")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 48, height: 48)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().stroke(.separator.opacity(0.6)))
            .shadow(color: .black.opacity(0.24), radius: 5, y: 2)
            .accessibilityLabel("This Mac, location you chose")
    }
}

struct LiveMapOriginControl: View {
    let isPlacing: Bool
    let hasOrigin: Bool
    let cancelPlacement: () -> Void
    let beginPlacement: () -> Void
    let clearOrigin: () -> Void

    @ViewBuilder
    var body: some View {
        if isPlacing {
            Text("Click the map to set your location").font(.caption)
            Button("Cancel", action: cancelPlacement)
        } else {
            Menu {
                Button(hasOrigin ? "Move My Location" : "Set My Location", action: beginPlacement)
                if hasOrigin { Button("Clear My Location", action: clearOrigin) }
            } label: {
                Label("My Location", systemImage: "location.circle")
            }
            .accessibilityLabel("My Location")
        }
    }
}

struct LiveMapInformation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Map").font(.headline)
            Text("Rift doesn’t look up where connections go. The map shows only the location you place for this Mac, and Rift saves it on this Mac only.")
            Text("Apple MapKit draws the map and requests map imagery from Apple as you pan and zoom. Rift sends Apple no destination addresses, hostnames, app identities, or firewall decisions.")
        }
        .font(.caption)
        .frame(width: 320, alignment: .leading)
        .padding(16)
    }
}

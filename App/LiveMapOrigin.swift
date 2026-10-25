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

struct LiveMapOriginControl: View {
    let hasOrigin: Bool
    let beginPlacement: () -> Void
    let clearOrigin: () -> Void

    var body: some View {
        Menu {
            Button(hasOrigin ? "Move My Location" : "Set My Location", action: beginPlacement)
            if hasOrigin { Button("Clear My Location", action: clearOrigin) }
        } label: {
            Label("My Location", systemImage: hasOrigin ? "location.fill" : "location")
        }
        .help("Set where this Mac is on the map")
    }
}

struct LiveMapInformation: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("About the map").font(.headline)
            Text("Lines show undersea internet cables. Solid lines are mapped cables; dashed lines are main sea routes drawn from where cables come ashore.")
            Text("When an app connects to another country, Rift highlights the cables the connection most likely uses. Rift looks up the country on your Mac and estimates the path. It can’t see the real route your data takes.")
            Text("Your location stays on this Mac. Apple Maps draws the map and gets no connection details from Rift.")
            Text("Cable data © OpenStreetMap contributors (ODbL). Country data from ip-location-db (public domain) and Natural Earth.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .frame(width: 340, alignment: .leading)
        .padding(16)
    }
}

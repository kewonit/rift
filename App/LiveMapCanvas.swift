import RiftControl
import RiftCore
import SwiftUI

/// The map area of Live Map: Apple Maps, undersea cables, and estimated routes
/// for the connections currently in the list.
struct LiveMapCanvas: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let displayed: [MonitorDisplayRow]
    let originController: MapOriginController
    let selectedEventIDs: Set<String>
    let windowIsVisible: Bool
    let isPreview: Bool
    let loadError: String?
    let style: NetworkMapStyle
    let fitRequest: Int
    let onReady: () -> Void
    private let store = NetworkMapStore.shared
    @State private var activity: [CountryActivity] = []
    @State private var destinations: [MapDestination] = []
    @State private var mapSelection: String?
    @State private var generation = 0

    private var highlighted: Set<String> {
        if let mapSelection { return [mapSelection] }
        guard !selectedEventIDs.isEmpty else { return [] }
        return Set(activity.filter { !selectedEventIDs.isDisjoint(with: $0.eventIDs) }.map(\.countryCode))
    }

    var body: some View {
        ZStack {
            if windowIsVisible {
                NetworkMapView(
                    resources: store.resources,
                    destinations: destinations,
                    origin: originController.origin,
                    isPlacingOrigin: originController.isPlacingManually,
                    highlightedCountries: highlighted,
                    style: style,
                    animatesFlow: !reduceMotion,
                    reduceMotion: reduceMotion,
                    fitRequest: fitRequest,
                    placeOrigin: placeOrigin,
                    selectCountry: { mapSelection = $0 }
                )
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
            overlays
        }
        .onAppear {
            store.load()
            onReady()
        }
        .onChange(of: displayed, initial: true) { _, _ in recompute() }
        .onChange(of: originController.origin) { _, _ in recompute() }
        .onChange(of: store.resources != nil) { _, _ in recompute() }
        .onChange(of: selectedEventIDs) { _, _ in mapSelection = nil }
        .onExitCommand {
            if originController.isPlacingManually { originController.cancelPlacement() } else { mapSelection = nil }
        }
    }

    @ViewBuilder
    private var overlays: some View {
        if originController.isPlacingManually {
            placementBanner
                .frame(maxHeight: .infinity, alignment: .top)
        } else if originController.origin == nil {
            ContentUnavailableView {
                Label("Set Your Location", systemImage: "location.circle")
            } description: {
                Text("Place this Mac on the map to see which undersea cables your connections likely use. Your location stays on this Mac.")
            } actions: {
                Button("Set My Location") { originController.beginManualPlacement() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: 380)
            .padding(28)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        }
        VStack(alignment: .leading, spacing: 8) {
            if let message = statusMessage {
                Label(message.text, systemImage: message.symbol)
                    .font(.callout)
                    .foregroundStyle(message.isError ? Color.orange : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }
            Spacer()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .allowsHitTesting(false)
        legend
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    private var placementBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.point.up.left.fill")
            Text("Click the map to place this Mac")
            Button("Cancel") { originController.cancelPlacement() }
                .controlSize(.small)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
        .padding(.top, 14)
    }

    private var legend: some View {
        HStack(spacing: 12) {
            LegendSwatch(dashed: false, title: "Cable", satellite: style == .satellite)
            LegendSwatch(dashed: true, title: "Estimated route", satellite: style == .satellite)
            Text("© OpenStreetMap")
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .accessibilityElement(children: .combine)
    }

    private var statusMessage: (text: String, symbol: String, isError: Bool)? {
        if let loadError { return (loadError, "exclamationmark.triangle.fill", true) }
        if store.loadFailed { return ("The cable map couldn’t load.", "exclamationmark.triangle.fill", true) }
        if originController.origin != nil, store.resources != nil, destinations.isEmpty {
            return ("No connections to other countries right now", "globe", false)
        }
        return nil
    }

    private func placeOrigin(_ coordinate: CoarseMapCoordinate) {
        originController.origin = CoarseMapOrigin(coordinate: coordinate)
        originController.cancelPlacement()
    }

    private func recompute() {
        let lookup: (IPAddress) -> String?
#if DEBUG
        if isPreview {
            lookup = MonitorFixtureData.countryCode(for:)
        } else {
            lookup = { store.countryCode(for: $0) }
        }
#else
        lookup = { store.countryCode(for: $0) }
#endif
        let grouped = store.resources == nil ? [] : CountryActivityBuilder.build(displayed, countryCode: lookup)
        activity = grouped
        generation &+= 1
        let current = generation
        let origin = originController.origin?.coordinate
        Task {
            let result = await store.destinations(for: grouped, origin: origin)
            guard current == generation else { return }
            if destinations != result { destinations = result }
            if let mapSelection, !result.contains(where: { $0.countryCode == mapSelection }) {
                self.mapSelection = nil
            }
        }
    }
}

private struct LegendSwatch: View {
    let dashed: Bool
    let title: String
    let satellite: Bool

    var body: some View {
        HStack(spacing: 5) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    path,
                    with: .color(satellite ? Color.primary.opacity(0.75) : Color(nsColor: .systemTeal)),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [4, 3] : [])
                )
            }
            .frame(width: 18, height: 6)
            .accessibilityHidden(true)
            Text(title)
        }
    }
}

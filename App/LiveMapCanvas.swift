import AppKit
import RiftControl
import RiftCore
import SwiftUI

/// The map on the Map page: Apple Maps, the faint cable network, and bold
/// estimated routes for the connections in the table.
struct LiveMapCanvas: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let displayed: [MonitorDisplayRow]
    let selectedCountry: String?
    /// Flow dots mean traffic is moving now, so they stop for past activity.
    let isViewingPast: Bool
    let selectCountry: (String?) -> Void
    let originController: MapOriginController
    let selectedEventIDs: Set<String>
    let windowIsVisible: Bool
    let isPreview: Bool
    /// The location prompt waits until the filter is on, so setup comes first.
    let promptsForLocation: Bool
    let loadError: String?
    let style: NetworkMapStyle
    let fitRequest: Int
    let onReady: () -> Void
    private let store = NetworkMapStore.shared
    @State private var activity: [CountryActivity] = []
    @State private var destinations: [MapDestination] = []
    @State private var localConnections = 0
    @State private var generation = 0
    /// MapKit holds a few hundred MB of tiles and textures. Keep the map while
    /// the window is only briefly hidden, then release it.
    @State private var keepsMap = true
    @State private var releaseTask: Task<Void, Never>?
    private static let releaseDelay: Duration = .seconds(30)

    private var highlighted: Set<String> {
        if let selectedCountry { return [selectedCountry] }
        guard !selectedEventIDs.isEmpty else { return [] }
        return Set(activity.filter { !selectedEventIDs.isDisjoint(with: $0.eventIDs) }.map(\.countryCode))
    }

    var body: some View {
        mapLayer
            .overlay { overlays }
            .onAppear {
                store.load()
                onReady()
            }
            .onChange(of: windowIsVisible, initial: true) { _, visible in scheduleRelease(visible) }
            .onDisappear { releaseTask?.cancel() }
            .onChange(of: displayed, initial: true) { _, _ in recompute() }
            .onChange(of: originController.origin) { _, _ in recompute() }
            .onChange(of: store.resources != nil) { _, _ in recompute() }
            .onExitCommand {
                if originController.isPlacingManually { originController.cancelPlacement() } else { selectCountry(nil) }
            }
    }

    @ViewBuilder
    private var mapLayer: some View {
        if keepsMap {
            networkMap
        } else {
            Color(nsColor: .windowBackgroundColor).ignoresSafeArea(.container, edges: .top)
        }
    }

    private func scheduleRelease(_ visible: Bool) {
        releaseTask?.cancel()
        releaseTask = nil
        if visible {
            keepsMap = true
            return
        }
        releaseTask = Task {
            try? await Task.sleep(for: Self.releaseDelay)
            guard !Task.isCancelled else { return }
            keepsMap = false
        }
    }

    private var networkMap: some View {
        NetworkMapView(
            resources: store.resources,
            destinations: destinations,
            origin: originController.origin,
            isPlacingOrigin: originController.isPlacingManually,
            highlightedCountries: highlighted,
            style: style,
            animatesFlow: windowIsVisible && !reduceMotion && !isViewingPast,
            reduceMotion: reduceMotion,
            fitRequest: fitRequest,
            placeOrigin: placeOrigin,
            selectCountry: selectCountry
        )
        // Only under the toolbar: under the sidebar and inspector, their glass
        // would pick up the color of the map.
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private var overlays: some View {
        ZStack {
            if originController.isPlacingManually {
                placementBanner
                    .frame(maxHeight: .infinity, alignment: .top)
            } else if originController.origin == nil, promptsForLocation {
                setLocationCard
            }
            if let message = statusMessage {
                Label(message.text, systemImage: message.symbol)
                    .font(.callout)
                    .foregroundStyle(message.isError ? Color(nsColor: .systemOrange) : Color.secondary)
                    .padding(.horizontal, RiftDesign.Spacing.m)
                    .padding(.vertical, RiftDesign.Spacing.xs + 2)
                    .riftPanel(cornerRadius: RiftDesign.Radius.card)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)
            }
            Text("© OpenStreetMap")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .allowsHitTesting(false)
        }
        .padding(RiftDesign.Spacing.m)
    }

    private var setLocationCard: some View {
        ContentUnavailableView {
            Label("Set Your Location", systemImage: "location.circle")
        } description: {
            Text("Place this Mac on the map to see which undersea cables your connections likely use. Your location stays on this Mac.")
        } actions: {
            Button("Set My Location") { originController.beginManualPlacement() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: 360)
        .padding(RiftDesign.Spacing.xl)
        .riftPanel()
    }

    private var placementBanner: some View {
        HStack(spacing: RiftDesign.Spacing.s) {
            Image(systemName: "hand.point.up.left.fill").accessibilityHidden(true)
            Text("Click the map to place this Mac")
            Button("Cancel") { originController.cancelPlacement() }
                .controlSize(.small)
        }
        .font(.callout.weight(.medium))
        .padding(.horizontal, RiftDesign.Spacing.l)
        .padding(.vertical, RiftDesign.Spacing.s)
        .riftPanel(cornerRadius: RiftDesign.Radius.card)
    }

    private var statusMessage: (text: String, symbol: String, isError: Bool)? {
        if let loadError { return (loadError, "exclamationmark.triangle.fill", true) }
        if store.loadFailed { return ("The cable map couldn’t load.", "exclamationmark.triangle.fill", true) }
        if originController.origin != nil, store.resources != nil, destinations.isEmpty, !displayed.isEmpty {
            return ("No connections to other countries right now", "globe", false)
        }
        if activity.count >= 12 { return ("Showing the 12 busiest countries", "globe", false) }
        if localConnections > 0 { return ("Local connections aren’t shown on the map", "house", false) }
        return nil
    }

    private func placeOrigin(_ coordinate: CoarseMapCoordinate) {
        originController.origin = CoarseMapOrigin(coordinate: coordinate)
        originController.cancelPlacement()
    }

    /// Groups rows by country off the main thread, then asks the store for
    /// routes. A newer request supersedes an older one.
    private func recompute() {
        generation &+= 1
        let current = generation
        let rows = displayed
        let origin = originController.origin?.coordinate
        guard let table = store.resources?.table else {
            activity = []; destinations = []
            return
        }
        let preview = isPreview
        Task {
            let grouped = await Task.detached(priority: .userInitiated) {
                CountryActivityBuilder.build(rows) { address in
#if DEBUG
                    if preview { return MonitorFixtureData.countryCode(for: address) }
#endif
                    return table.countryCode(for: address)
                }
            }.value
            guard current == generation else { return }
            if activity != grouped { activity = grouped }
            let result = await store.destinations(for: grouped, origin: origin)
            guard current == generation else { return }
            if destinations != result { destinations = result }
            if let selectedCountry, !result.contains(where: { $0.countryCode == selectedCountry }) {
                selectCountry(nil)
            }
            localConnections = rows.filter {
                !($0.source.event.flow.destinationEndpoint?.classes.isEmpty ?? true)
            }.count
        }
    }
}

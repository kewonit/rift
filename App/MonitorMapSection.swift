import RiftControl
import SwiftUI

struct MonitorMapSection: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let rows: [MonitorDisplayRow]
    let metadata: GeoDatabaseMetadata?
    let isPreview: Bool
    @Binding var selectedLocationID: String?
    @Bindable var originController: MonitorOriginController
    let geolocation: GeolocationController
    let onMapReady: () -> Void
    @State private var showingInformation = false

    private static let dbIPURL = URL(string: "https://db-ip.com")
    private static let licenseURL = URL(string: "https://creativecommons.org/licenses/by/4.0/")

    private var selection: MonitorMapSelection {
        MonitorMapSelector.select(from: rows, selectedID: selectedLocationID)
    }

    private var points: [DestinationMapPoint] {
        selection.markers.map { candidate in
            DestinationMapPoint(
                id: candidate.id,
                latitude: candidate.location.latitude,
                longitude: candidate.location.longitude,
                title: candidate.location.displayName,
                count: candidate.count
            )
        }
    }

    private var accessibilitySummary: String {
        "Showing \(selection.markers.count) of \(selection.totalLocationCount) locations"
    }

    var body: some View {
        mapSurface
        .overlay(alignment: .topTrailing) { originControls }
        .overlay(alignment: .topLeading) { attribution }
        .overlay {
            if points.isEmpty {
                ContentUnavailableView(
                    "No mapped destinations",
                    systemImage: "map",
                    description: Text("The current filters contain no public located endpoints.")
                )
                .frame(maxWidth: 360)
            }
        }
        .onExitCommand { originController.cancelPlacement() }
    }

    @ViewBuilder
    private var mapSurface: some View {
#if DEBUG
        if isPreview && !MonitorFixtureData.usesLiveMap {
            DestinationMapPreviewView(
                points: points,
                linkedPointIDs: originController.origin == nil ? [] : Set(selection.links.map(\.id)),
                accessibilityValue: accessibilitySummary,
                selectionID: $selectedLocationID,
                origin: $originController.origin,
                isPlacingOrigin: $originController.isPlacingManually,
                onReady: onMapReady
            )
        } else {
            liveMap
        }
#else
        liveMap
#endif
    }

    private var liveMap: some View {
        DestinationMapView(
            points: points,
            linkedPointIDs: originController.origin == nil ? [] : Set(selection.links.map(\.id)),
            accessibilityValue: accessibilitySummary,
            selectionID: $selectedLocationID,
            origin: $originController.origin,
            isPlacingOrigin: $originController.isPlacingManually,
            reduceMotion: reduceMotion,
            onReady: onMapReady
        )
    }

    private var originControls: some View {
        HStack(spacing: 6) {
            if originController.isPlacingManually {
                Text("Click to set origin")
                    .font(.caption)
                Button("Cancel") { originController.cancelPlacement() }
            } else if originController.isLocating {
                ProgressView()
                    .controlSize(.small)
                Text("Finding network location…")
                    .font(.caption)
            } else if originController.origin == nil {
                Button {
                    originController.locate(using: geolocation)
                } label: {
                    Label(
                        originController.automaticLookupFailed
                            ? "Retry Network Location" : "Use Network Location",
                        systemImage: "location.circle"
                    )
                }
                Menu {
                    Button("Set Manually") { originController.beginManualPlacement() }
                } label: {
                    Label("Origin Options", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
            } else {
                Button {
                    originController.clearOrigin()
                } label: {
                    Label("Clear Origin", systemImage: "scope")
                }
            }
        }
        .controlSize(.small)
        .padding(7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(8)
    }

    private var attribution: some View {
        HStack(spacing: 5) {
            if let url = Self.dbIPURL {
                Link("IP Geolocation by DB-IP", destination: url)
            } else {
                Text("IP Geolocation by DB-IP")
            }
            Button {
                showingInformation.toggle()
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Map information")
            .popover(isPresented: $showingInformation) { information }
        }
        .font(.caption2)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
        .padding(8)
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Approximate locations").font(.headline)
            if let metadata {
                Text("\(metadata.sourceName) · \(metadata.sourceVersion)")
                Text("Imported \(metadata.importedAt.formatted(date: .abbreviated, time: .omitted))")
            }
            Text("Connection links use an approximate network origin, not an observed packet route or precise device location.")
            Text("CDNs, VPNs, and relays may represent an observed endpoint rather than a service owner.")
            Text("Rift asks api64.ipify.org for the public IP once per map session, resolves it with the local DB-IP database, then keeps only a coarse coordinate in memory.")
            Text("MapKit requests tiles for viewed regions. Destination IPs and application identities are not sent to ipify or DB-IP.")
            if let url = Self.licenseURL {
                Link("DB-IP City Lite · CC BY 4.0", destination: url)
            } else {
                Text("DB-IP City Lite · CC BY 4.0")
            }
        }
        .font(.caption)
        .frame(width: 310, alignment: .leading)
        .padding(14)
    }
}

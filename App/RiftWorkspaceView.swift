import AppKit
import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case liveMap
    case rules
    case health

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveMap: "Map"
        case .rules: "Rules"
        case .health: "Status"
        }
    }

    var symbol: String {
        switch self {
        case .liveMap: "globe.americas.fill"
        case .rules: "list.bullet.rectangle"
        case .health: "checkmark.shield"
        }
    }

    init?(deepLink url: URL) {
        guard url.scheme?.lowercased() == "rift" else { return nil }
        let value = url.host?.lowercased() ?? url.pathComponents.dropFirst().first?.lowercased()
        switch value {
        // Activity now lives in the Map page's connection table.
        case "map", "live-map", "activity": self = .liveMap
        case "rules": self = .rules
        case "health", "status": self = .health
        default: return nil
        }
    }
}

struct RiftRootView: View {
    @Bindable var session: AppSession

    var body: some View {
#if DEBUG
        if MonitorFixtureData.usesStatusMenuPreview {
            StatusMenuFixtureHost(session: session)
        } else if FixturePreviewOptions.showsAlert {
            AlertFixtureHost(session: session)
        } else {
            RiftWorkspaceView(session: session)
        }
#else
        RiftWorkspaceView(session: session)
#endif
    }
}

struct RiftWorkspaceView: View {
    @Bindable var session: AppSession
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        destinationView
            .navigationTitle("Rift")
            .frame(minWidth: 1_000, minHeight: 600)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $session.destination) {
                        ForEach(AppDestination.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .help("Switch views")
                }
            }
            .onOpenURL { url in
                let target = (url.host ?? url.pathComponents.dropFirst().first)?.lowercased()
                if url.scheme?.lowercased() == "rift", target == "settings" {
                    openSettings()
                } else if let destination = AppDestination(deepLink: url) {
                    session.destination = destination
                    if target == "activity" { session.showsConnectionTable = true }
                }
            }
#if DEBUG
            .task {
                if session.isUIFixture, FixturePreviewOptions.opensSettings { openSettings() }
            }
#endif
            .onChange(of: session.showingFilterStatus) { _, showing in
                guard showing else { return }
                session.destination = .health
                session.showingFilterStatus = false
            }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch session.destination {
        case .liveMap:
            LiveMapView(session: session)
        case .rules:
            RulesWorkspaceView(
                controlPlane: session.controlPlane,
                requestedSelection: Binding(
                    get: { session.requestedRuleIDs },
                    set: { session.requestedRuleIDs = $0 }
                ),
                artworkStore: session.applicationArtwork,
                isPreview: session.isUIFixture
            )
        case .health:
            RiftHealthView(session: session)
        }
    }
}

struct RiftNavigationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let session: AppSession

    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(Array(AppDestination.allCases.enumerated()), id: \.element.id) { index, item in
                Button(item.title) { navigate(to: item) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
    }

    private func navigate(to destination: AppDestination) {
        session.destination = destination
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

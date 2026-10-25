import AppKit
import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case liveMap
    case activity
    case rules
    case health
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveMap: "Live Map"
        case .activity: "Activity"
        case .rules: "Rules"
        case .health: "Health"
        case .settings: "Settings"
        }
    }

    var symbol: String {
        switch self {
        case .liveMap: "globe.americas.fill"
        case .activity: "waveform.path.ecg"
        case .rules: "list.bullet.rectangle"
        case .health: "checkmark.shield"
        case .settings: "gearshape"
        }
    }

    init?(deepLink url: URL) {
        guard url.scheme?.lowercased() == "rift" else { return nil }
        let value = url.host?.lowercased() ?? url.pathComponents.dropFirst().first?.lowercased()
        switch value {
        case "map", "live-map": self = .liveMap
        case "activity": self = .activity
        case "rules": self = .rules
        case "health": self = .health
        case "settings": self = .settings
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

    var body: some View {
        destinationView
            .navigationTitle(session.destination.title)
            .frame(minWidth: 1_000, minHeight: 600)
            .toolbar { workspaceNavigation }
        .onOpenURL { url in
            if let destination = AppDestination(deepLink: url) {
                session.destination = destination
            }
        }
        .onChange(of: session.showingFilterStatus) { _, showing in
            guard showing else { return }
            session.destination = .health
            session.showingFilterStatus = false
        }
    }

    @ToolbarContentBuilder
    private var workspaceNavigation: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            HStack(spacing: 3) {
                ForEach(AppDestination.allCases) { destination in
                    RiftWorkspaceDestinationButton(
                        destination: destination,
                        selected: session.destination == destination,
                        action: { session.destination = destination }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var destinationView: some View {
        switch session.destination {
        case .liveMap:
            LiveMapView(session: session)
        case .activity:
            MonitorView(session: session)
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
        case .settings:
            SettingsView(
                controlPlane: session.controlPlane,
                lifecycle: session.lifecycle,
                isPreview: session.isUIFixture
            )
        }
    }

}

private struct RiftWorkspaceDestinationButton: View {
    let destination: AppDestination
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: destination.symbol)
                .symbolVariant(selected ? .fill : .none)
                .frame(width: 29, height: 25)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : .secondary)
        .background(
            selected ? Color.accentColor.opacity(0.14) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .accessibilityLabel(destination.title)
        .accessibilityValue(selected ? "Selected" : "")
        .help(destination.title)
    }
}

struct RiftHealthView: View {
    @Bindable var session: AppSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RiftDesign.Spacing.section) {
                healthHeader
                if let issue = session.controlPlane.startupIssue {
                    HealthCard(
                        title: "Rift found a problem",
                        detail: issue,
                        tone: .warning,
                        symbol: "externaldrive.badge.exclamationmark"
                    )
                }
                extensionCard
                dataCard
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(RiftDesign.Spacing.spacious)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.35))
    }

    private var healthHeader: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: session.hasConfirmedFilterService
                ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 36))
                .foregroundStyle(session.hasConfirmedFilterService ? Color.green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(session.isUIFixture
                    ? "Preview mode"
                    : (session.hasConfirmedFilterService ? "Rift is protecting this Mac" : "Rift needs attention"))
                    .font(.title2.weight(.semibold))
                Text(session.isUIFixture
                    ? "This preview shows sample setup and error states. Nothing on this Mac changes."
                    : session.statusAccessibilityLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var extensionCard: some View {
        if showsHealthSetupFixture {
            HealthCard(
                title: "Set up the network filter",
                detail: "The filter isn’t installed in this preview. Install and approve it from a signed copy of Rift.",
                tone: .warning,
                symbol: "network.badge.shield.half.filled"
            )
        } else if let lifecycle = session.lifecycle {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    lifecycle.initialStatusResolved ? lifecycle.title : "Checking the network filter…",
                    systemImage: "network.badge.shield.half.filled"
                )
                .font(.headline)
                Text(lifecycle.initialStatusResolved
                    ? lifecycle.guidance
                    : "Rift is checking the filter’s status with macOS.")
                    .foregroundStyle(.secondary)

                HStack {
                    if lifecycle.initialStatusResolved, case .notInstalled = lifecycle.state {
                        Button("Install and Enable") { lifecycle.installAndEnable() }
                            .disabled(lifecycle.operationInProgress)
                    }
                    if lifecycle.shouldOfferRetry {
                        Button("Try Again") { lifecycle.retrySetup() }
                    }
                    if lifecycle.initialStatusResolved && lifecycle.shouldOfferSettings {
                        Button("Open System Settings") { lifecycle.openSystemSettings() }
                    }
                    Spacer()
                    Button("Copy Status Report") { lifecycle.copyRedactedDiagnostics() }
                        .help("Copy a short status report for troubleshooting. It doesn’t include personal details.")
                }
            }
            .padding(16)
            .riftSurface()
        } else {
            HealthCard(
                title: "Network filter",
                detail: "This preview uses sample data. The network filter isn’t running.",
                tone: .unresolved,
                symbol: "network.badge.shield.half.filled"
            )
        }
    }

    private var showsHealthSetupFixture: Bool {
#if DEBUG
        session.isUIFixture && MonitorFixtureData.scenario == .healthSetup
#else
        false
#endif
    }

    private var dataCard: some View {
        HealthCard(
            title: "Map",
            detail: NetworkMapStore.shared.loadFailed
                ? "The cable map couldn’t load. Filtering isn’t affected."
                : "Rift finds each connection’s country on this Mac and estimates the undersea cables it uses. Apple Maps draws the map and gets no connection details from Rift.",
            tone: NetworkMapStore.shared.loadFailed ? .warning : .protected,
            symbol: "map"
        )
    }
}

private struct HealthCard: View {
    let title: String
    let detail: String
    let tone: RiftStatusTone
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tone.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            RiftStatusBadge(tone: tone)
        }
        .padding(16)
        .riftSurface()
        .accessibilityElement(children: .combine)
    }
}

struct RiftNavigationCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    let session: AppSession

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { navigate(to: .settings) }
                .keyboardShortcut(",", modifiers: .command)
        }
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

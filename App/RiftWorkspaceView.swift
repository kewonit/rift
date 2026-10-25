import AppKit
import SwiftUI

enum AppDestination: String, CaseIterable, Identifiable, Hashable {
    case liveMap
    case activity
    case rules
    case health

    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveMap: "Map"
        case .activity: "Activity"
        case .rules: "Rules"
        case .health: "Status"
        }
    }

    var symbol: String {
        switch self {
        case .liveMap: "globe.americas.fill"
        case .activity: "waveform.path.ecg"
        case .rules: "list.bullet.rectangle"
        case .health: "checkmark.shield"
        }
    }

    init?(deepLink url: URL) {
        guard url.scheme?.lowercased() == "rift" else { return nil }
        let value = url.host?.lowercased() ?? url.pathComponents.dropFirst().first?.lowercased()
        switch value {
        case "map", "live-map": self = .liveMap
        case "activity": self = .activity
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
                }
            }
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
        }
    }
}

struct RiftHealthView: View {
    @Bindable var session: AppSession

    var body: some View {
        Form {
            Section {
                header
            }
            if let issue = session.controlPlane.startupIssue {
                Section {
                    StatusRow(
                        title: "Rift found a problem",
                        detail: issue,
                        tone: .warning,
                        symbol: "externaldrive.badge.exclamationmark"
                    )
                }
            }
            Section("Network Filter") {
                filterSection
            }
            Section("Map") {
                StatusRow(
                    title: NetworkMapStore.shared.loadFailed ? "Cable map unavailable" : "Cable map ready",
                    detail: NetworkMapStore.shared.loadFailed
                        ? "The cable map couldn’t load. Filtering isn’t affected."
                        : "Rift finds each connection’s country on this Mac and estimates the undersea cables it uses. Apple Maps gets no connection details from Rift.",
                    tone: NetworkMapStore.shared.loadFailed ? .warning : .protected,
                    symbol: "map"
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: session.hasConfirmedFilterService
                ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(session.hasConfirmedFilterService ? Color.green : .orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.isUIFixture
                    ? "Preview Mode"
                    : (session.hasConfirmedFilterService ? "Rift is protecting this Mac" : "Rift needs attention"))
                    .font(.title3.weight(.semibold))
                Text(session.isUIFixture
                    ? "This preview shows sample data. Nothing on this Mac changes."
                    : session.statusAccessibilityLabel)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var filterSection: some View {
        if showsHealthSetupFixture {
            StatusRow(
                title: "Set up the network filter",
                detail: "The filter isn’t installed in this preview. Install and approve it from a signed copy of Rift.",
                tone: .warning,
                symbol: "network.badge.shield.half.filled"
            )
        } else if let lifecycle = session.lifecycle {
            StatusRow(
                title: lifecycle.initialStatusResolved ? lifecycle.title : "Checking the network filter…",
                detail: lifecycle.initialStatusResolved
                    ? lifecycle.guidance
                    : "Rift is checking the filter’s status with macOS.",
                tone: session.hasConfirmedFilterService ? .protected : .warning,
                symbol: "network.badge.shield.half.filled"
            )
            HStack {
                Button("Copy Status Report") { lifecycle.copyRedactedDiagnostics() }
                    .help("Copy a short status report for troubleshooting. It doesn’t include personal details.")
                Spacer()
                if lifecycle.initialStatusResolved && lifecycle.shouldOfferSettings {
                    Button("Open System Settings") { lifecycle.openSystemSettings() }
                }
                if lifecycle.shouldOfferRetry {
                    Button("Try Again") { lifecycle.retrySetup() }
                }
                if lifecycle.initialStatusResolved, case .notInstalled = lifecycle.state {
                    Button("Install and Enable") { lifecycle.installAndEnable() }
                        .buttonStyle(.borderedProminent)
                        .disabled(lifecycle.operationInProgress)
                }
            }
        } else {
            StatusRow(
                title: "Not running in preview",
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
}

private struct StatusRow: View {
    let title: String
    let detail: String
    let tone: RiftStatusTone
    let symbol: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tone.color)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            RiftStatusBadge(tone: tone)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
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

import AppKit
import RiftControl
import SwiftUI

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
            if status.state != .preview, status.state != .cannotFilter {
                Section {
                    StatusRow(
                        title: "Your rules",
                        detail: status.rulesSummary,
                        tone: rulesRowTone,
                        symbol: "list.bullet.rectangle"
                    )
                }
            }
            Section("Map") {
                StatusRow(
                    title: NetworkMapStore.shared.loadFailed ? "Cable map unavailable" : "Cable map ready",
                    detail: NetworkMapStore.shared.loadFailed
                        ? "The cable map couldn’t load. Filtering isn’t affected."
                        : "Rift finds each connection’s country on this Mac and estimates the undersea cables it uses. Apple Maps gets no connection details from Rift.",
                    tone: NetworkMapStore.shared.loadFailed ? .warning : .allowed,
                    symbol: "map",
                    badge: NetworkMapStore.shared.loadFailed ? nil : "Ready"
                )
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: 720)
        .frame(maxWidth: .infinity)
    }

    private var status: ProtectionStatus { session.protectionStatus }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: status.filledSymbolName)
                .font(.system(size: 34))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status.color)
                .frame(width: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.title)
                    .font(.title3.weight(.semibold))
                Text(status.detail)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var filterRowTone: RiftStatusTone {
        if session.hasConfirmedFilterService { return .on }
        return status.tone == .attention ? .warning : .unresolved
    }

    private var rulesRowTone: RiftStatusTone {
        switch status.state {
        case .active(.filterOff): .unresolved
        case .active, .waiting: .on
        default: status.tone == .attention ? .warning : .unresolved
        }
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
        } else if status.state == .cannotFilter {
            StatusRow(
                title: "Filtering isn’t available in this copy",
                detail: "You can look around, but Rift can’t see or block real connections here. Filtering needs a copy signed with Apple’s network filter permission.",
                tone: .unresolved,
                symbol: "network.badge.shield.half.filled"
            )
        } else if let lifecycle = session.lifecycle {
            StatusRow(
                title: lifecycle.initialStatusResolved ? lifecycle.title : "Checking the network filter…",
                detail: lifecycle.initialStatusResolved
                    ? lifecycle.guidance
                    : "Rift is checking the filter’s status with macOS.",
                tone: filterRowTone,
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
                    Button(lifecycle.retryTitle) { lifecycle.retrySetup() }
                        .buttonStyle(.borderedProminent)
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
    var badge: String?

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
            RiftStatusBadge(tone: tone, label: badge)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }
}

import RiftControl
import RiftCore
import SwiftUI

/// The top of the menu-bar panel: status and mode, traffic over the last five
/// minutes, and the apps that connected most recently.
struct StatusMenuDashboard: View {
    let status: ProtectionStatus
    let mode: OperationMode
    let profile: String?
    let snapshot: StatusMenuSnapshot
    let now: Date
    let keepsHistory: Bool
    let notificationsEnabled: Bool
    let canChangeMode: Bool
    let artworkStore: ApplicationArtworkStore
    let selectMode: (OperationMode) -> Void
    let performAction: (ProtectionStatus.Action) -> Void
    let toggleNotifications: () -> Void
    let openConnection: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.m) {
            StatusMenuHeader(
                status: status, mode: mode, profile: profile,
                canChangeMode: canChangeMode, selectMode: selectMode,
                performAction: performAction
            )
            .equatable()
            HStack {
                Text("Notify about new connections")
                Spacer(minLength: RiftDesign.Spacing.s)
                Toggle("Notify about new connections", isOn: Binding(
                    get: { notificationsEnabled }, set: { _ in toggleNotifications() }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.horizontal, RiftDesign.Spacing.xs + 2)
            StatusMenuTraffic(traffic: snapshot.traffic).equatable()
            recent
        }
    }

    @ViewBuilder
    private var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, RiftDesign.Spacing.xs + 2)
                .padding(.bottom, RiftDesign.Spacing.xs)
            if snapshot.applications.isEmpty {
                Text(keepsHistory
                    ? "No connections in the last 5 minutes"
                    : "Watching since you opened this panel. Turn on history in Settings to see earlier connections.")
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, RiftDesign.Spacing.xs + 2)
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            } else {
                ForEach(snapshot.applications) { item in
                    StatusMenuButton(action: { openConnection(item.eventID) }) {
                        HStack(spacing: RiftDesign.Spacing.s) {
                            ApplicationIdentityIcon(
                                identity: item.identity, fallbackSystemName: "app.dashed",
                                size: 18, artworkStore: artworkStore
                            )
                            VStack(alignment: .leading, spacing: 0) {
                                ApplicationNameText(identity: item.identity, fallback: item.name, artworkStore: artworkStore)
                                    .lineLimit(1)
                                Text(item.destination)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: RiftDesign.Spacing.s)
                            Text(RiftRelativeTime.short(item.occurredAt, now: now))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            RiftDecisionBadge(decision: item.decision)
                        }
                    }
                    .accessibilityHint("Shows this connection in Rift")
                }
            }
            if snapshot.deniedCount > 0 {
                StatusMenuButton(action: { snapshot.latestDeniedID.map(openConnection) }) {
                    HStack(spacing: RiftDesign.Spacing.s) {
                        RiftDecisionBadge(decision: .denied).frame(width: 18)
                        Text(snapshot.deniedCount == 1 ? "1 connection blocked" : "\(snapshot.deniedCount) connections blocked")
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .accessibilityHint("Shows the most recent denied connection")
            }
        }
    }
}

enum RiftRelativeTime {
    static func short(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 10 { return "now" }
        if seconds < 60 { return "\(Int(seconds))s" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

/// Status and mode. Equatable so the once-a-second activity refresh doesn't
/// rebuild the mode menu.
private struct StatusMenuHeader: View, Equatable {
    let status: ProtectionStatus
    let mode: OperationMode
    let profile: String?
    let canChangeMode: Bool
    let selectMode: (OperationMode) -> Void
    let performAction: (ProtectionStatus.Action) -> Void

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.status == rhs.status && lhs.mode == rhs.mode
            && lhs.profile == rhs.profile && lhs.canChangeMode == rhs.canChangeMode
    }

    private var modeIsUnreadable: Bool {
        if case .configurationUnreadable = status.state { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.xs) {
            HStack(spacing: RiftDesign.Spacing.s + 2) {
                Image(systemName: status.filledSymbolName)
                    .font(.title2)
                    .foregroundStyle(status.color)
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                Text(status.title).font(.headline).lineLimit(2)
                Spacer(minLength: RiftDesign.Spacing.s)
                Menu {
                    Section(profile.map { "Mode for \($0)" } ?? "Mode") {
                        ForEach(OperationMode.choices, id: \.self) { choice in
                            Toggle(isOn: Binding(
                                get: { choice == mode },
                                set: { if $0 { selectMode(choice) } }
                            )) {
                                Text(choice.displayName)
                                Text(choice.summary)
                            }
                        }
                    }
                } label: {
                    Text(modeIsUnreadable ? "Unknown" : mode.displayName)
                }
                .fixedSize()
                .controlSize(.small)
                .disabled(!canChangeMode || modeIsUnreadable)
                .help(canChangeMode ? "Change how Rift handles connections without a rule" : "Finish setup first")
            }
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if status.action == nil, let profile {
                Text("Profile: \(profile)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let action = status.action {
                Button(action.title) { performAction(action) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, RiftDesign.Spacing.xxs)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// Traffic over the last five minutes.
private struct StatusMenuTraffic: View, Equatable {
    let traffic: LiveTrafficSnapshot

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs.traffic == rhs.traffic }

    var body: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.s) {
            HStack(spacing: RiftDesign.Spacing.s) {
                Text("Last 5 minutes").foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Label {
                    RiftBytesText(bytes: traffic.sent, partial: traffic.partial)
                } icon: {
                    Image(systemName: "arrow.up").foregroundStyle(RiftDesign.trafficSent)
                }
                Label {
                    RiftBytesText(bytes: traffic.received, partial: traffic.partial)
                } icon: {
                    Image(systemName: "arrow.down").foregroundStyle(RiftDesign.trafficReceived)
                }
            }
            .font(.caption)
            TrafficBars(snapshot: traffic)
                .frame(height: 34)
        }
        .padding(RiftDesign.Spacing.s + 2)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: RiftDesign.Radius.card, style: .continuous))
    }
}

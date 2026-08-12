import AbyssControl
import AbyssCore
import SwiftUI

struct MonitorSidebarView: View {
    @Binding var query: MonitorQueryState
    @Binding var selectionID: String?
    let hierarchy: [MonitorHierarchyNode]
    let rows: [String: MonitorEventRow]
    let summary: MonitorSummarySnapshot
    let controlPlane: ControlPlaneController
    let artworkStore: ApplicationArtworkStore
    let now: Date
    let attentionMessage: String?
    let errorMessage: String?
    let loading: Bool
    let hasMore: Bool
    let applyingEventID: String?
    let availableLenses: [MonitorLens]
    let showFilterStatus: () -> Void
    let loadMore: () -> Void
    let apply: (FilterAction, MonitorHierarchyNode) -> Void
    let showRules: (Set<UUID>) -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            if let attentionMessage {
                Button(action: showFilterStatus) {
                    Label(attentionMessage, systemImage: "exclamationmark.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
            }
            activityList
            Divider()
#if DEBUG
            if MonitorFixtureBytePresentation.isEnabled {
                trafficTotals
            }
#endif
            DecisionChartView(controlPlane: controlPlane, query: $query, now: now)
                .padding(.horizontal, 8)
                .padding(.bottom, 7)
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(spacing: 6) {
            TextField("Search", text: $query.search)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 28)
            Picker("Group by", selection: $query.lens) {
                ForEach(availableLenses) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            filters
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    private var filters: some View {
        Menu {
            Picker("Decision", selection: $query.decision) {
                ForEach(MonitorDecisionFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Direction", selection: $query.direction) {
                ForEach(MonitorDirectionFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Sort", selection: $query.sort) {
                ForEach(availableSorts) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Label("Filters", systemImage: "line.3.horizontal.decrease")
                .labelStyle(.iconOnly)
        }
        .help("Filter and sort activity")
    }

    private var activityList: some View {
        List(selection: $selectionID) {
            OutlineGroup(hierarchy, children: \.children) { node in
                MonitorHierarchyRow(
                    node: node,
                    row: node.ruleSeedEventID.flatMap { rows[$0] },
                    isApplying: applyingEventID == node.ruleSeedEventID,
                    artworkStore: artworkStore,
                    apply: { apply($0, node) },
                    showRules: { showRules(node.ruleCoverage.ruleIDs) }
                )
                .tag(node.id)
            }
            if hasMore {
                Button(action: loadMore) {
                    Label("Load more", systemImage: "arrow.down.circle")
                }
                .disabled(loading)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if hierarchy.isEmpty && !loading {
                ContentUnavailableView("No activity", systemImage: "network")
            }
        }
    }

#if DEBUG
    private var trafficTotals: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { trafficChips }
            VStack(spacing: 5) { trafficChips }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var trafficChips: some View {
        TrafficTotalChip(
            title: "Sent",
            systemImage: "arrow.up",
            total: summary.sent,
            color: .purple
        )
        TrafficTotalChip(
            title: "Received",
            systemImage: "arrow.down",
            total: summary.received,
            color: .blue
        )
    }
#endif

    private var availableSorts: [MonitorSort] {
#if DEBUG
        MonitorSort.available(
            allowsUnverifiedBytePreview: MonitorFixtureBytePresentation.isEnabled
        )
#else
        MonitorSort.available(allowsUnverifiedBytePreview: false)
#endif
    }
}

struct MonitorToolbarContent: ToolbarContent {
    let isPreview: Bool
    let canShowMap: Bool
    let showingMap: Bool
    let showFilterStatus: () -> Void
    let openRules: () -> Void
    let toggleMap: () -> Void
    let refresh: () -> Void

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        if isPreview {
            ToolbarItem {
                Text("Preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Preview data. This is not live filtering.")
            }
        } else {
            ToolbarItem {
                Button(action: showFilterStatus) {
                    Label("Filter Status", systemImage: "shield")
                }
            }
        }
        ToolbarItemGroup {
            Button(action: openRules) {
                Label("Rules", systemImage: "list.bullet.rectangle")
            }
            if canShowMap {
                Button(action: toggleMap) {
                    Label(showingMap ? "Hide Map" : "Show Map", systemImage: "map")
                }
            }
            Button(action: refresh) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            SettingsLink {
                Label("Settings", systemImage: "gearshape")
            }
        }
    }
}

#if DEBUG
enum MonitorFixtureBytePresentation {
    static var isEnabled: Bool { MonitorFixtureData.isRequested }
}

private struct TrafficTotalChip: View {
    let title: String
    let systemImage: String
    let total: ReportedByteTotal
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title).font(.caption)
            Spacer(minLength: 2)
            Text(formatted)
                .font(.callout.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, minHeight: 26)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .help(helpText)
    }

    private var formatted: String {
        guard let value = total.value else { return "—" }
        let bytes = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value), countStyle: .file
        )
        return total.isPartial ? "≥\(bytes)" : bytes
    }

    private var helpText: String {
        total.isPartial
            ? "Lower bound from reported completed connections"
            : "Reported when connections closed"
    }
}
#endif

private struct MonitorHierarchyRow: View {
    let node: MonitorHierarchyNode
    let row: MonitorEventRow?
    let isApplying: Bool
    let artworkStore: ApplicationArtworkStore
    let apply: (FilterAction) -> Void
    let showRules: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if node.kind == .application || node.kind == .helper {
                ApplicationIdentityIcon(
                    identity: node.presentationIdentity,
                    fallbackSystemName: symbol,
                    size: 18,
                    artworkStore: artworkStore
                )
            } else {
                Image(systemName: symbol)
                    .frame(width: 18)
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title).lineLimit(1)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text("\(node.aggregate.flowCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if let row, MonitorExactRuleSeed.make(from: row) != nil {
                HStack(spacing: 0) {
                    Button { apply(.allow) } label: {
                        Image(systemName: "checkmark")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 20, height: 18)
                    .accessibilityLabel("Allow exact connection")
                    Divider().frame(height: 13)
                    Button { apply(.deny) } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 20, height: 18)
                    .accessibilityLabel("Deny exact connection")
                }
                .controlSize(.mini)
                .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
                .disabled(isApplying || monitorCoveragePending(node.ruleCoverage.state))
            }
        }
        .accessibilityElement(children: .contain)
        .frame(minHeight: 25)
        .help(monitorCoverageLabel(node.ruleCoverage.state))
        .contextMenu {
            Button("Show Corresponding Rules", action: showRules)
                .disabled(node.ruleCoverage.ruleIDs.isEmpty)
        }
    }

    private var symbol: String {
        switch node.kind {
        case .application: "app.dashed"
        case .helper: "gearshape.2"
        case .route: "arrow.left.arrow.right"
        case .hostname: "globe"
        case .address: "network"
        case .country: "globe.europe.africa"
        case .city: "building.2"
        case .nonGeographic: "mappin.slash"
        case .flow: row?.event.action == .deny ? "xmark.circle.fill" : "checkmark.circle.fill"
        }
    }

    private var symbolColor: Color {
        guard node.kind == .flow, let row else { return .secondary }
        return row.event.action == .deny ? .red : .accentColor
    }
}

func monitorCoveragePending(_ state: MonitorRuleCoverageState) -> Bool {
    state == .savedPendingEnforcement || state == .persistedPendingProvider
        || state == .applyFailed
}

func monitorCoverageLabel(_ state: MonitorRuleCoverageState) -> String {
    switch state {
    case .exact: "Exact rule"
    case .broader: "Broader rule"
    case .narrower: "Partial coverage"
    case .mixed: "Mixed rules"
    case .savedPendingEnforcement: "Saved"
    case .persistedPendingProvider: "Persisted"
    case .applyFailed: "Apply failed"
    case .unresolved: "Unresolved"
    case .policyChanged: "Policy changed"
    case .historicalRuleMissing: "Historical rule missing"
    case .identityChanged: "Identity changed"
    case .hostnameUnavailable: "Hostname unavailable"
    case .noRule: "No rule"
    }
}

@MainActor func monitorAttentionMessage(for lifecycle: FilterLifecycleController?) -> String? {
    guard let lifecycle, lifecycle.initialStatusResolved else { return nil }
    switch lifecycle.state {
    case .notInstalled:
        return "Set up the network filter"
    case .awaitingApproval:
        return "Approve Abyss in System Settings"
    case .denied, .disabled, .failed:
        return "The network filter needs attention"
    default:
        return nil
    }
}

struct MonitorManagedListOverrideConfirmation: ViewModifier {
    @Binding var pending: MonitorHierarchyNode?
    let confirm: (MonitorHierarchyNode) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Allow a Managed-List Exception?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending {
                Button("Allow Exact Connection") {
                    self.pending = nil
                    confirm(pending)
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("This exact allow applies only to the selected application and destination, and outranks matching managed lists.")
        }
    }
}

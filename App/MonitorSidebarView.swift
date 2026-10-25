import RiftControl
import RiftCore
import SwiftUI

struct MonitorSidebarView: View {
    @Binding var query: MonitorQueryState
    @Binding var selectionID: String?
    let hierarchy: [MonitorHierarchyNode]
    let rows: [String: MonitorEventRow]
    let summary: MonitorSummarySnapshot
    let isPreview: Bool
    let controlPlane: ControlPlaneController
    let artworkStore: ApplicationArtworkStore
    let now: Date
    let decisionSnapshot: DecisionBucketSnapshot
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
            DecisionChartView(snapshot: decisionSnapshot, query: $query, now: now,
                              refreshFailed: errorMessage != nil, isMinimal: controlPlane.isMinimalActivity)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Search activity", text: $query.search)
                    .textFieldStyle(.plain)
                if !query.search.isEmpty {
                    Button { query.search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear Search")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 30)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            Menu {
                Picker("Group By", selection: $query.lens) {
                    ForEach(availableLenses) { Text($0.rawValue).tag($0) }
                }
            } label: {
                Label("Group By", systemImage: "square.stack.3d.up")
            }
            .labelStyle(.iconOnly)
            .help("Group by " + query.lens.rawValue.lowercased())
            filters
            if isPreview {
                ViewThatFits(in: .horizontal) {
                    Text("Preview")
                    Image(systemName: "eye")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Preview mode. Rift isn’t filtering.")
                .accessibilityLabel("Preview mode. Rift isn’t filtering.")
            } else {
                Button(action: showFilterStatus) {
                    Label("Filter Status", systemImage: "shield")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Show filter status")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var filters: some View {
        Menu {
            Picker("Decision", selection: $query.decision) {
                ForEach(MonitorDecisionFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Direction", selection: $query.direction) {
                ForEach(MonitorDirectionFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Network", selection: $query.locality) {
                ForEach(MonitorLocalityFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            Picker("Owner", selection: $query.owner) {
                ForEach(MonitorOwnerFilter.allCases) { Text($0.rawValue).tag($0) }
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
                    Label("Load More", systemImage: "arrow.down.circle")
                }
                .disabled(loading)
            }
        }
        .listStyle(.inset)
        .overlay {
            if hierarchy.isEmpty && !loading {
                ContentUnavailableView(
                    controlPlane.isMinimalActivity
                        ? (rows.isEmpty && query.search.isEmpty ? "Waiting for new connections" : "No matching connections")
                        : "No activity yet",
                    systemImage: "network",
                    description: controlPlane.isMinimalActivity
                        ? Text("New connections appear while this view is open. Rift keeps up to \(ControlPlaneController.minimalFlowLimit) for five minutes and doesn’t save them.") : nil
                )
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
            color: RiftDesign.trafficSent
        )
        TrafficTotalChip(
            title: "Received",
            systemImage: "arrow.down",
            total: summary.received,
            color: RiftDesign.trafficReceived
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
    @Binding var showingSummary: Bool

    var body: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showingSummary.toggle() } label: {
                Label(showingSummary ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.right")
            }
            .help(showingSummary ? "Hide the inspector" : "Show the inspector")
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
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(title).font(.callout).foregroundStyle(.secondary)
            Spacer(minLength: 2)
            Text(formatted)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, minHeight: 22)
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
            ? "At least this much, based on connections that have closed"
            : "Counted when connections close"
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
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
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
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if hovering, let row, MonitorExactRuleSeed.make(from: row) != nil {
                HStack(spacing: 2) {
                    Button { apply(.allow) } label: { Image(systemName: "checkmark.circle") }
                        .help("Allow this connection")
                        .accessibilityLabel("Allow this connection")
                    Button { apply(.deny) } label: { Image(systemName: "xmark.circle") }
                        .help("Deny this connection")
                        .accessibilityLabel("Deny this connection")
                }
                .buttonStyle(.borderless)
                .imageScale(.large)
                .foregroundStyle(.secondary)
                .disabled(isApplying || monitorCoveragePending(node.ruleCoverage.state))
            } else {
                if node.aggregate.denied > 0 {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .imageScale(.small)
                        .accessibilityLabel(node.aggregate.denied == 1 ? "1 denied" : "\(node.aggregate.denied) denied")
                }
                Text("\(node.aggregate.flowCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .frame(minHeight: 26)
        .help(monitorCoverageLabel(node.ruleCoverage.state))
        .contextMenu {
            Button("Show Matching Rules", action: showRules)
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
    case .exact: "Matched by an exact rule"
    case .broader: "Matched by a broader rule"
    case .narrower: "Partly covered by rules"
    case .mixed: "Covered by different rules"
    case .savedPendingEnforcement: "Rule saved, waiting for the filter"
    case .persistedPendingProvider: "Rule saved, waiting for the filter"
    case .applyFailed: "Rule couldn’t be applied"
    case .unresolved: "Decided by default"
    case .policyChanged: "Rules changed since this connection"
    case .historicalRuleMissing: "The rule that decided this was removed"
    case .identityChanged: "The app’s identity changed"
    case .hostnameUnavailable: "Hostname unavailable"
    case .noRule: "No matching rule"
    }
}

@MainActor func monitorAttentionMessage(for lifecycle: FilterLifecycleController?) -> String? {
    guard let lifecycle, lifecycle.initialStatusResolved else { return nil }
    switch lifecycle.state {
    case .notInstalled:
        return "Set up the network filter"
    case .awaitingApproval:
        return "Approve Rift in System Settings"
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
            "Allow this blocklisted connection?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending {
                Button("Allow This Connection") {
                    self.pending = nil
                    confirm(pending)
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("This allows only this app and destination, and overrides your blocklists for them.")
        }
    }
}

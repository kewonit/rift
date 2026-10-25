import RiftControl
import RiftCore
import SwiftUI

struct LiveMapConnectionsPane: View {
    @Binding var query: MonitorQueryState
    @Binding var selectionID: String?
    let displayed: [MonitorDisplayRow]
    let hierarchy: [MonitorHierarchyNode]
    let rows: [String: MonitorEventRow]
    let loading: Bool
    var isMinimal = false
    let artworkStore: ApplicationArtworkStore
    let availableLenses: [MonitorLens]
    let now: Date
    let traffic: LiveTrafficSnapshot
    let applyingEventID: String?
    @Binding var showingTrafficChart: Bool
    let apply: (FilterAction, MonitorHierarchyNode) -> Void
    let investigate: (MonitorHierarchyNode) -> Void
    let showRules: (Set<UUID>) -> Void

    @State private var hierarchySort = LiveHierarchySort.activity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var sortedHierarchy: [MonitorHierarchyNode] {
        hierarchy.sorted(by: hierarchySort.comparator)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            Divider()
            connectionList
            if showingTrafficChart {
                Divider()
                LiveTrafficChart(
                    snapshot: traffic,
                    query: $query,
                    now: now, isMinimal: isMinimal
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(
            reduceMotion ? nil : .easeOut(duration: RiftDesign.Motion.contextual),
            value: showingTrafficChart
        )
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Search connections", text: $query.search)
                .textFieldStyle(.plain)
            if !query.search.isEmpty {
                Button { query.search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                    .accessibilityLabel("Clear Search")
            }
            Divider().frame(height: 20)
            groupMenu
            filterMenu
            sortMenu
            if loading { ProgressView().controlSize(.small) }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .frame(height: 30)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    private var groupMenu: some View {
        Menu {
            Picker("Group By", selection: $query.lens) {
                ForEach(availableLenses) { value in
                    Label(value.menuLabel, systemImage: value.symbol).tag(value)
                }
            }
        } label: {
            Label("Group By", systemImage: query.lens.symbol)
        }
        .labelStyle(.iconOnly)
        .help("Group by " + query.lens.menuLabel.lowercased())
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $hierarchySort) {
                ForEach(LiveHierarchySort.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
        } label: {
            Label("Sort", systemImage: "clock")
        }
        .labelStyle(.iconOnly)
        .help("Sort by " + hierarchySort.rawValue.lowercased())
    }

    private var filterMenu: some View {
        Menu {
            Picker("Decision", selection: $query.decision) {
                ForEach(MonitorDecisionFilter.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            Picker("Direction", selection: $query.direction) {
                ForEach(MonitorDirectionFilter.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            Picker("Network", selection: $query.locality) {
                ForEach(MonitorLocalityFilter.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            Picker("Owner", selection: $query.owner) {
                ForEach(MonitorOwnerFilter.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            Divider()
            Button("Clear Filters") {
                query.decision = .all
                query.direction = .all
                query.locality = .all
                query.owner = .all
            }
            .disabled(!hasActiveFilters)
        } label: {
            Label("Filters", systemImage: hasActiveFilters
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease.circle")
        }
        .labelStyle(.iconOnly)
        .help(filterSummary)
    }

    private var connectionList: some View {
        List(selection: $selectionID) {
            OutlineGroup(sortedHierarchy, children: \.children) { node in
                LiveMapHierarchyRow(
                    node: node,
                    row: node.ruleSeedEventID.flatMap { rows[$0] },
                    isApplying: applyingEventID == node.ruleSeedEventID,
                    artworkStore: artworkStore,
                    apply: { apply($0, node) },
                    investigate: { investigate(node) },
                    showRules: { showRules(node.ruleCoverage.ruleIDs) }
                )
                .tag(node.id)
            }
        }
        .listStyle(.inset)
        .overlay {
            if hierarchy.isEmpty && !loading {
                ContentUnavailableView(
                    query.search.isEmpty ? (isMinimal ? "Waiting for new connections" : "No connections yet") : "No matching connections",
                    systemImage: "network.slash",
                    description: isMinimal ? Text("New connections appear while this view is open. They aren’t saved.") : nil
                )
            }
        }
    }

    private var hasActiveFilters: Bool {
        query.decision != .all || query.direction != .all
            || query.locality != .all || query.owner != .all
    }

    private var filterSummary: String {
        guard hasActiveFilters else { return "Filter connections" }
        return [
            query.decision.rawValue,
            query.direction.rawValue,
            query.locality.rawValue,
            query.owner.rawValue,
        ].filter {
            !["All decisions", "All directions", "All networks", "All owners"].contains($0)
        }.joined(separator: ", ")
    }
}

private struct LiveMapHierarchyRow: View {
    let node: MonitorHierarchyNode
    let row: MonitorEventRow?
    let isApplying: Bool
    let artworkStore: ApplicationArtworkStore
    let apply: (FilterAction) -> Void
    let investigate: () -> Void
    let showRules: () -> Void
    @State private var hovering = false

    private var canDecide: Bool { row != nil && node.exactRuleSeed != nil }

    var body: some View {
        HStack(spacing: 8) {
            identity
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if canDecide, hovering {
                exactActions
            } else {
                trailingDetail
            }
        }
        .frame(minHeight: 26)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .help(monitorCoverageLabel(node.ruleCoverage.state))
        .contextMenu {
            Button("Show in Activity", action: investigate)
            Button("Show Matching Rules", action: showRules)
                .disabled(node.ruleCoverage.ruleIDs.isEmpty)
            if canDecide {
                Divider()
                Button("Allow This Connection") { apply(.allow) }
                    .disabled(isApplying || monitorCoveragePending(node.ruleCoverage.state))
                Button("Deny This Connection") { apply(.deny) }
                    .disabled(isApplying || monitorCoveragePending(node.ruleCoverage.state))
            }
        }
    }

    @ViewBuilder
    private var identity: some View {
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
    }

    private var trailingDetail: some View {
        HStack(spacing: 6) {
            if node.aggregate.denied > 0 {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .imageScale(.small)
                    .help(node.aggregate.denied == 1 ? "1 denied" : "\(node.aggregate.denied) denied")
                    .accessibilityLabel(node.aggregate.denied == 1 ? "1 denied" : "\(node.aggregate.denied) denied")
            }
            Text(totalBytes.map(byteLabel) ?? "\(node.aggregate.flowCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .help(totalBytes == nil ? "Connections" : "Total traffic")
        }
    }

    private var exactActions: some View {
        HStack(spacing: 2) {
            Button { apply(.allow) } label: {
                Image(systemName: "checkmark.circle")
            }
            .help("Allow this connection")
            .accessibilityLabel("Allow this connection")
            Button { apply(.deny) } label: {
                Image(systemName: "xmark.circle")
            }
            .help("Deny this connection")
            .accessibilityLabel("Deny this connection")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .foregroundStyle(.secondary)
        .disabled(isApplying || monitorCoveragePending(node.ruleCoverage.state))
    }

    private var totalBytes: UInt64? {
        guard node.aggregate.bytesInbound != nil || node.aggregate.bytesOutbound != nil else {
            return nil
        }
        let (sum, overflow) = (node.aggregate.bytesInbound ?? 0)
            .addingReportingOverflow(node.aggregate.bytesOutbound ?? 0)
        return overflow ? .max : sum
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
        if row.event.reason != .concreteDecision { return .orange }
        return row.event.action == .deny ? .red : .green
    }
}

private enum LiveHierarchySort: String, CaseIterable, Identifiable {
    case activity = "Most Recent"
    case name = "Name"
    case traffic = "Total Traffic"
    case sent = "Data Sent"
    case received = "Data Received"
    case denied = "Most Denied"
    var id: String { rawValue }

    func comparator(_ lhs: MonitorHierarchyNode, _ rhs: MonitorHierarchyNode) -> Bool {
        switch self {
        case .activity:
            if lhs.aggregate.lastSeen != rhs.aggregate.lastSeen {
                return lhs.aggregate.lastSeen > rhs.aggregate.lastSeen
            }
        case .name:
            let order = lhs.title.localizedStandardCompare(rhs.title)
            if order != .orderedSame { return order == .orderedAscending }
        case .traffic:
            let left = totalTraffic(lhs.aggregate)
            let right = totalTraffic(rhs.aggregate)
            if left != right { return left > right }
        case .sent:
            if lhs.aggregate.bytesOutbound != rhs.aggregate.bytesOutbound {
                return (lhs.aggregate.bytesOutbound ?? 0) > (rhs.aggregate.bytesOutbound ?? 0)
            }
        case .received:
            if lhs.aggregate.bytesInbound != rhs.aggregate.bytesInbound {
                return (lhs.aggregate.bytesInbound ?? 0) > (rhs.aggregate.bytesInbound ?? 0)
            }
        case .denied:
            if lhs.aggregate.denied != rhs.aggregate.denied {
                return lhs.aggregate.denied > rhs.aggregate.denied
            }
        }
        return lhs.id < rhs.id
    }

    private func totalTraffic(_ value: MonitorAggregate) -> UInt64 {
        let (total, overflow) = (value.bytesInbound ?? 0)
            .addingReportingOverflow(value.bytesOutbound ?? 0)
        return overflow ? .max : total
    }
}

private extension MonitorLens {
    var menuLabel: String {
        switch self {
        case .application: "App"
        case .hostname: "Hostname"
        }
    }

    var symbol: String {
        switch self {
        case .application: "app"
        case .hostname: "globe"
        }
    }
}

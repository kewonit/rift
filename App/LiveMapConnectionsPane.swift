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
        .background(.bar)
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
        .padding(.horizontal, 9)
        .frame(height: 34)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 9))
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
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
        .listStyle(.sidebar)
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

    var body: some View {
        HStack(spacing: 7) {
            identity
            VStack(alignment: .leading, spacing: 1) {
                Text(node.title)
                    .font(node.kind == .application ? .body.weight(.semibold) : .body)
                    .lineLimit(1)
                if let subtitle = node.subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            traffic
            if row != nil, node.exactRuleSeed != nil {
                exactActions
            }
        }
        .frame(minHeight: 31)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .help(monitorCoverageLabel(node.ruleCoverage.state))
        .contextMenu {
            Button("Show in Activity", action: investigate)
            Button("Show Matching Rules", action: showRules)
                .disabled(node.ruleCoverage.ruleIDs.isEmpty)
            if row != nil, node.exactRuleSeed != nil {
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
                size: 19,
                artworkStore: artworkStore
            )
        } else {
            Image(systemName: symbol)
                .frame(width: 19)
                .foregroundStyle(symbolColor)
                .accessibilityHidden(true)
        }
    }

    private var traffic: some View {
        MiniTrafficMeter(
            sent: node.aggregate.bytesOutbound ?? 0,
            received: node.aggregate.bytesInbound ?? 0,
            seed: node.aggregate.flowCount
        )
        .help(totalBytes.map(byteLabel) ?? "No traffic data yet")
    }

    private var exactActions: some View {
        HStack(spacing: 0) {
            Button { apply(.deny) } label: {
                Image(systemName: "xmark")
                    .frame(width: 19, height: 18)
                    .foregroundStyle(node.aggregate.denied > 0 ? Color.white : .secondary)
                    .background(node.aggregate.denied > 0 ? Color.red : Color.clear)
            }
                .accessibilityLabel("Deny this connection")
            Divider().frame(height: 13)
            Button { apply(.allow) } label: {
                Image(systemName: "checkmark")
                    .frame(width: 19, height: 18)
                    .foregroundStyle(node.aggregate.allowed > 0 ? Color.white : .secondary)
                    .background(node.aggregate.allowed > 0 ? Color.green : Color.clear)
            }
                .accessibilityLabel("Allow this connection")
        }
        .buttonStyle(.borderless)
        .controlSize(.mini)
        .frame(width: 40, height: 19)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(.separator.opacity(0.55)))
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

private struct MiniTrafficMeter: View {
    let sent: UInt64
    let received: UInt64
    let seed: Int

    var body: some View {
        Canvas { context, size in
            let count = 7
            let gap: CGFloat = 1.5
            let width = (size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            let middle = size.height / 2
            let maximum = max(1, max(sent, received))
            let sentRatio = CGFloat(sent) / CGFloat(maximum)
            let receivedRatio = CGFloat(received) / CGFloat(maximum)
            for index in 0..<count {
                let x = CGFloat(index) * (width + gap)
                let background = CGRect(x: x, y: 0, width: width, height: size.height)
                context.fill(
                    Path(roundedRect: background, cornerRadius: width / 2),
                    with: .color(Color.secondary.opacity(0.10))
                )
                let modulation = CGFloat(((index + seed) % 4) + 5) / 8
                let up = max(1, (middle - 1) * sentRatio * modulation)
                let down = max(1, (middle - 1) * receivedRatio * modulation)
                context.fill(
                    Path(roundedRect: CGRect(
                        x: x, y: middle - up, width: width, height: up
                    ), cornerRadius: width / 2),
                    with: .color(RiftDesign.trafficSent.opacity(0.9))
                )
                context.fill(
                    Path(roundedRect: CGRect(
                        x: x, y: middle, width: width, height: down
                    ), cornerRadius: width / 2),
                    with: .color(Color.blue.opacity(0.9))
                )
            }
        }
        .frame(width: 35, height: 20)
        .accessibilityHidden(true)
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

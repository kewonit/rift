import RiftControl
import RiftCore
import SwiftUI

/// The floating connection list on the Map page. Expanding it swaps the
/// outline for a full table with columns.
struct ConnectionsPanel: View {
    @Bindable var feed: MonitorFeed
    let artworkStore: ApplicationArtworkStore
    let expanded: Bool
    let toggleExpanded: () -> Void
    var searchFocus: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if expanded {
                ConnectionsTable(feed: feed, artworkStore: artworkStore)
            } else {
                list
            }
            if feed.hasMore {
                Divider().opacity(0.5)
                Button("Show More Connections") { feed.loadMore() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.vertical, RiftDesign.Spacing.s)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.s) {
            HStack(spacing: RiftDesign.Spacing.s) {
                Text("Connections").font(.headline)
                if feed.displayedCount > 0 {
                    Text(RiftFormat.count(feed.displayedCount))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if feed.loading { ProgressView().controlSize(.small) }
                Button(action: toggleExpanded) {
                    Label(
                        expanded ? "Show Map" : "Show Table",
                        systemImage: expanded
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Return to the map (⌘T)" : "Show all connections in a table (⌘T)")
                .keyboardShortcut("t", modifiers: .command)
            }
            RiftSearchField(prompt: "Search apps and destinations", text: $feed.query.search, focus: searchFocus)
                .background {
                    // ⌘F focuses search without a visible button.
                    Button("Find") { searchFocus.wrappedValue = true }
                        .keyboardShortcut("f", modifiers: .command)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            ConnectionFilterBar(feed: feed)
        }
        .padding(RiftDesign.Spacing.m)
    }

    private var list: some View {
        List(selection: $feed.selectionID) {
            OutlineGroup(feed.hierarchy, children: \.children) { node in
                ConnectionRow(
                    node: node,
                    row: node.ruleSeedEventID.flatMap { feed.rowLookup[$0] },
                    isApplying: feed.applyingEventID != nil && feed.applyingEventID == node.ruleSeedEventID,
                    artworkStore: artworkStore,
                    apply: { feed.apply($0, to: node) },
                    showRules: { feed.showRules(node.ruleCoverage.ruleIDs) }
                )
                .tag(node.id)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if feed.hierarchy.isEmpty, !feed.loading { emptyState }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let status = feed.session.protectionStatus
        if status.canShowActivity {
            ContentUnavailableView {
                Label(
                    feed.query.search.isEmpty
                        ? (feed.isMinimal ? "Waiting for Connections" : "No Connections")
                        : "No Matches",
                    systemImage: feed.query.search.isEmpty ? "network" : "magnifyingglass"
                )
            } description: {
                if feed.isMinimal, feed.query.search.isEmpty {
                    Text("New connections appear while this window is open. They aren’t saved.")
                }
            }
            .controlSize(.small)
        } else {
            ContentUnavailableView {
                Label("No Connections to Show", systemImage: "network.slash")
            } description: {
                Text("Rift can’t see connections until the network filter is on.")
            } actions: {
                Button("Show Status") { feed.session.destination = .health }
            }
            .controlSize(.small)
        }
    }
}

/// Group, filter and sort, as labeled menus.
struct ConnectionFilterBar: View {
    @Bindable var feed: MonitorFeed

    private var activeFilterCount: Int {
        [feed.query.decision != .all, feed.query.direction != .all,
         feed.query.locality != .all, feed.query.owner != .all].filter { $0 }.count
    }

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.s) {
            Menu {
                Picker("Group By", selection: $feed.query.lens) {
                    ForEach(MonitorLens.allCases) { Text($0.groupTitle).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("By \(feed.query.lens.groupTitle)")
            }
            .help("Group connections")
            Menu {
                Picker("Decision", selection: $feed.query.decision) {
                    ForEach(MonitorDecisionFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Direction", selection: $feed.query.direction) {
                    ForEach(MonitorDirectionFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Network", selection: $feed.query.locality) {
                    ForEach(MonitorLocalityFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                Picker("Owner", selection: $feed.query.owner) {
                    ForEach(MonitorOwnerFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("Clear Filters") {
                    feed.query.decision = .all
                    feed.query.direction = .all
                    feed.query.locality = .all
                    feed.query.owner = .all
                }
                .disabled(activeFilterCount == 0)
            } label: {
                Text(activeFilterCount == 0 ? "Filter" : "Filter (\(activeFilterCount))")
            }
            .help("Filter connections")
            Menu {
                Picker("Sort By", selection: $feed.sort) {
                    ForEach(MonitorHierarchySort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text(feed.sort.rawValue)
            }
            .help("Sort connections")
            Spacer(minLength: 0)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
        .controlSize(.small)
        .font(.callout)
    }
}

extension MonitorLens {
    var groupTitle: String {
        switch self {
        case .application: "App"
        case .hostname: "Destination"
        }
    }
}

/// The overall decision for a group of connections.
extension MonitorAggregate {
    var decision: RiftDecision {
        if denied > 0, allowed == 0 { return .denied }
        if unresolved > 0, allowed == 0, denied == 0 { return .byDefault }
        return .allowed
    }

    var totalBytes: UInt64? {
        guard bytesInbound != nil || bytesOutbound != nil else { return nil }
        let (sum, overflow) = (bytesInbound ?? 0).addingReportingOverflow(bytesOutbound ?? 0)
        return overflow ? .max : sum
    }
}

/// One app, destination or connection in the floating list.
struct ConnectionRow: View {
    let node: MonitorHierarchyNode
    let row: MonitorEventRow?
    let isApplying: Bool
    let artworkStore: ApplicationArtworkStore
    let apply: (FilterAction) -> Void
    let showRules: () -> Void
    @State private var hovering = false

    private var canDecide: Bool { row != nil && node.exactRuleSeed != nil }
    private var pending: Bool { monitorCoveragePending(node.ruleCoverage.state) }

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.s) {
            ConnectionIdentityIcon(node: node, row: row, artworkStore: artworkStore, size: 18)
            VStack(alignment: .leading, spacing: 1) {
                if node.kind == .application {
                    ApplicationNameText(identity: node.presentationIdentity, fallback: node.title, artworkStore: artworkStore)
                        .lineLimit(1)
                } else {
                    Text(node.title).lineLimit(1).truncationMode(.middle)
                }
                if let subtitle = node.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: RiftDesign.Spacing.xs)
            if canDecide, hovering {
                ConnectionDecisionButtons(disabled: isApplying || pending, apply: apply)
            } else {
                trailing
            }
        }
        .frame(minHeight: 28)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(monitorCoverageLabel(node.ruleCoverage.state))
        .accessibilityElement(children: .contain)
        .contextMenu {
            ConnectionContextMenu(
                canDecide: canDecide, disabled: isApplying || pending,
                hasRules: !node.ruleCoverage.ruleIDs.isEmpty, apply: apply, showRules: showRules
            )
        }
    }

    /// Says when today's rules differ from what this row recorded.
    private var futureChange: String? {
        switch node.ruleCoverage.currentAction {
        case .deny where node.aggregate.denied == 0: "Blocked from now on"
        case .allow where node.aggregate.denied > 0: "Allowed from now on"
        default: nil
        }
    }

    private var trailing: some View {
        HStack(spacing: RiftDesign.Spacing.xs + 2) {
            if let change = futureChange {
                Text(change)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .fixedSize()
                    .transition(.opacity)
            } else {
                if node.aggregate.denied > 0 {
                    RiftDecisionBadge(decision: .denied)
                        .imageScale(.small)
                        .accessibilityLabel(node.aggregate.denied == 1 ? "1 blocked" : "\(node.aggregate.denied) blocked")
                }
                if let bytes = node.aggregate.totalBytes {
                    RiftBytesText(bytes: bytes, partial: node.aggregate.coverage != .complete)
                        .help("Total traffic")
                } else {
                    Text(node.aggregate.flowCount == 1 ? "1 connection" : "\(node.aggregate.flowCount) connections")
                        .monospacedDigit()
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .animation(.easeOut(duration: RiftDesign.Motion.press), value: futureChange)
    }
}

struct ConnectionIdentityIcon: View {
    let node: MonitorHierarchyNode
    let row: MonitorEventRow?
    let artworkStore: ApplicationArtworkStore
    let size: CGFloat

    var body: some View {
        if node.kind == .application || node.kind == .helper {
            ApplicationIdentityIcon(
                identity: node.presentationIdentity,
                fallbackSystemName: node.kind == .helper ? "gearshape.2" : "app.dashed",
                size: size,
                artworkStore: artworkStore
            )
        } else if node.kind == .flow, let row {
            RiftDecisionBadge(decision: row.decision).frame(width: size)
        } else {
            Image(systemName: node.kind == .route ? "arrow.left.arrow.right" : node.kind == .hostname ? "globe" : "network")
                .foregroundStyle(.secondary)
                .frame(width: size)
                .accessibilityHidden(true)
        }
    }
}

struct ConnectionDecisionButtons: View {
    let disabled: Bool
    let apply: (FilterAction) -> Void

    var body: some View {
        HStack(spacing: 2) {
            Button { apply(.allow) } label: { Image(systemName: "checkmark.circle") }
                .help("Always allow this connection")
                .accessibilityLabel("Always allow this connection")
            Button { apply(.deny) } label: { Image(systemName: "xmark.circle") }
                .help("Always block this connection")
                .accessibilityLabel("Always block this connection")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
        .foregroundStyle(.secondary)
        .disabled(disabled)
    }
}

struct ConnectionContextMenu: View {
    let canDecide: Bool
    let disabled: Bool
    let hasRules: Bool
    let apply: (FilterAction) -> Void
    let showRules: () -> Void

    var body: some View {
        if canDecide {
            Button("Always Allow") { apply(.allow) }.disabled(disabled)
            Button("Always Block") { apply(.deny) }.disabled(disabled)
            Divider()
        }
        Button("Show Matching Rules", action: showRules).disabled(!hasRules)
    }
}

extension MonitorEventRow {
    var decision: RiftDecision {
        if event.outcome == .blocked { return .denied }
        return switch event.cause {
        case .rule, .yourAnswer: .allowed
        case .alertTimedOut, .alertUnavailable: .timedOut
        case .mode, .noActiveRules: .byDefault
        }
    }
}

import RiftControl
import RiftCore
import SwiftUI

/// The connections pane under the map: one slim bar of filters over the table.
struct ConnectionsPanel: View {
    @Bindable var feed: MonitorFeed
    let artworkStore: ApplicationArtworkStore
    let mapHidden: Bool
    let toggleMap: () -> Void
    var searchFocus: FocusState<Bool>.Binding

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ConnectionsTable(feed: feed, artworkStore: artworkStore)
                .overlay(alignment: .bottom) { orderPausedNote }
            if feed.hasMore {
                Divider()
                Button("Show More Connections") { feed.loadMore() }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .padding(.vertical, RiftDesign.Spacing.s)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.xs) {
            HStack(spacing: RiftDesign.Spacing.m) {
                HStack(alignment: .firstTextBaseline, spacing: RiftDesign.Spacing.xs + 2) {
                    Text("Connections").font(.headline)
                    if feed.displayedCount > 0 {
                        Text(RiftFormat.count(feed.displayedCount))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                ConnectionFilterBar(feed: feed)
                if feed.loading { ProgressView().controlSize(.small) }
                RiftSearchField(prompt: "Search apps and destinations", text: $feed.query.search, focus: searchFocus)
                Button(action: toggleMap) {
                    Label(
                        mapHidden ? "Show Map" : "Hide Map",
                        systemImage: mapHidden
                            ? "arrow.down.right.and.arrow.up.left"
                            : "arrow.up.left.and.arrow.down.right"
                    )
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.borderless)
                .help(mapHidden ? "Show the map (⌘T)" : "Hide the map to see more connections (⌘T)")
            }
            if feed.query.isViewingPast {
                HStack(spacing: RiftDesign.Spacing.s) {
                    Label("Viewing past activity", systemImage: "clock.arrow.circlepath")
                        .font(.callout)
                    Spacer(minLength: 0)
                    Button("Back to Live") { feed.query.showNow() }
                        .controlSize(.small)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: RiftDesign.Motion.press), value: feed.query.isViewingPast)
        .padding(.horizontal, RiftDesign.Spacing.m)
        .padding(.vertical, RiftDesign.Spacing.s)
    }

    @ViewBuilder
    private var orderPausedNote: some View {
        if feed.orderIsPaused {
            Text("Order paused while you point at the list")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, RiftDesign.Spacing.s)
                .padding(.vertical, RiftDesign.Spacing.xxs)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, RiftDesign.Spacing.xs)
                .allowsHitTesting(false)
        }
    }
}

/// Says why the list is empty, because each reason has a different next step.
struct ConnectionsEmptyState: View {
    @Bindable var feed: MonitorFeed

    private var isFiltered: Bool {
        !feed.query.search.isEmpty || feed.query.country != nil || feed.query.decision != .all
            || feed.query.direction != .all || feed.query.locality != .all || feed.query.owner != .all
    }

    var body: some View {
        if !feed.session.protectionStatus.canShowActivity {
            ContentUnavailableView {
                Label("No Connections to Show", systemImage: "network.slash")
            } description: {
                Text("Rift can’t see connections until the network filter is on.")
            } actions: {
                Button("Show Status") { feed.session.destination = .health }
            }
        } else if isFiltered {
            ContentUnavailableView {
                Label("No Matches", systemImage: "magnifyingglass")
            } description: {
                Text("Nothing matches your search and filters.")
            } actions: {
                Button("Clear Filters") { feed.query.clearExcludingFilters() }
            }
        } else if feed.isMinimal {
            ContentUnavailableView(
                "Waiting for Connections",
                systemImage: "network",
                description: Text("New connections appear while this window is open. They aren’t saved.")
            )
        } else {
            ContentUnavailableView(
                "No Connections",
                systemImage: "network",
                description: Text("Nothing connected in this time range.")
            )
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
            if let country = feed.query.country {
                Button {
                    feed.query.country = nil
                } label: {
                    Label(
                        Locale.autoupdatingCurrent.localizedString(forRegionCode: country) ?? country,
                        systemImage: "xmark.circle.fill"
                    )
                    .lineLimit(1)
                }
                .buttonStyle(.borderless)
                .help("Show every country again")
            }
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
        if denied > 0 { return allowed == 0 && unresolved == 0 ? .denied : .mixed }
        if unresolved > 0, allowed == 0 { return .byDefault }
        return .allowed
    }

    var totalBytes: UInt64? {
        guard bytesInbound != nil || bytesOutbound != nil else { return nil }
        let (sum, overflow) = (bytesInbound ?? 0).addingReportingOverflow(bytesOutbound ?? 0)
        return overflow ? .max : sum
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

struct ConnectionContextMenu: View {
    let canDecide: () -> Bool
    let disabled: Bool
    let hasRules: Bool
    let apply: (FilterAction) -> Void
    let showRules: () -> Void

    var body: some View {
        if canDecide() {
            Button("Allow…") { apply(.allow) }.disabled(disabled)
            Button("Block…") { apply(.deny) }.disabled(disabled)
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

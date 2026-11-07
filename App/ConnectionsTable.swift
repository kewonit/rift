import RiftControl
import RiftCore
import SwiftUI

/// Every connection in a table with columns, docked under the map.
struct ConnectionsTable: View {
    @Bindable var feed: MonitorFeed
    let artworkStore: ApplicationArtworkStore

    var body: some View {
        Table(feed.hierarchy, children: \.children, selection: $feed.selectionID) {
            TableColumn("App or Destination") { node in
                HStack(spacing: RiftDesign.Spacing.s) {
                    ConnectionIdentityIcon(node: node, row: row(for: node), artworkStore: artworkStore, size: 16)
                    if node.kind == .application {
                        ApplicationNameText(identity: node.presentationIdentity, fallback: node.title, artworkStore: artworkStore)
                            .lineLimit(1)
                    } else {
                        Text(node.title).lineLimit(1).truncationMode(.middle).layoutPriority(1)
                    }
                    if let subtitle = node.subtitle {
                        Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(monitorCoverageLabel(node.ruleCoverage.state))
                .accessibilityAction(named: "Allow…") { feed.requestRule(.allow, for: node) }
                .accessibilityAction(named: "Block…") { feed.requestRule(.deny, for: node) }
                .accessibilityAction(named: "Show Rule") { feed.showRules(for: node) }
            }
            .width(min: 140, ideal: 170)
            TableColumn("Country") { node in
                let country = countryName(for: node)
                Text(country ?? "—")
                    .foregroundStyle(country == nil ? .tertiary : .primary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 76)
            TableColumn("Decision") { node in
                DecisionCell(node: node)
            }
            .width(min: 84, ideal: 100)
            TableColumn("Sent") { node in
                RiftBytesText(bytes: node.aggregate.bytesOutbound, partial: node.aggregate.coverage != .complete)
            }
            .width(min: 52, ideal: 60)
            .alignment(.trailing)
            TableColumn("Received") { node in
                RiftBytesText(bytes: node.aggregate.bytesInbound, partial: node.aggregate.coverage != .complete)
            }
            .width(min: 56, ideal: 64)
            .alignment(.trailing)
            TableColumn("Count") { node in
                Text(RiftFormat.count(node.aggregate.flowCount)).monospacedDigit()
            }
            .width(min: 44, ideal: 50)
            .alignment(.trailing)
            TableColumn("Last Seen") { node in
                // The clock ticks once a second, so a new row can be slightly ahead of it.
                Text(Self.relativeFormatter.localizedString(
                    for: min(node.aggregate.lastSeen, feed.now), relativeTo: feed.now
                ))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 60, ideal: 70)
        }
        .alternatingRowBackgrounds(.disabled)
        .onHover { feed.pointerIsOverList = $0 }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, ids.count == 1,
               let node = MonitorHierarchyBuilder.node(withID: id, in: feed.hierarchy) {
                ConnectionContextMenu(
                    canDecide: { feed.canDecide(node) },
                    disabled: feed.applyingEventID != nil || monitorCoveragePending(node.ruleCoverage.state),
                    hasRules: !node.ruleCoverage.ruleIDs.isEmpty,
                    apply: { feed.requestRule($0, for: node) },
                    showRules: { feed.showRules(for: node) }
                )
            }
        }
        .overlay {
            if feed.hierarchy.isEmpty, !feed.loading {
                ConnectionsEmptyState(feed: feed)
            }
        }
    }

    @MainActor private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        return formatter
    }()

    private func row(for node: MonitorHierarchyNode) -> MonitorEventRow? {
        (node.eventID ?? node.ruleSeedEventID).flatMap { feed.rowLookup[$0] }
    }

    /// The destination country, for nodes that have a single destination.
    private func countryName(for node: MonitorHierarchyNode) -> String? {
        if (node.children?.count ?? 0) > 1 { return "Several" }
        guard let address = row(for: node)?.event.flow.destinationEndpoint?.address else { return nil }
        let code: String?
#if DEBUG
        code = feed.session.isUIFixture
            ? MonitorFixtureData.countryCode(for: address)
            : NetworkMapStore.shared.countryCode(for: address)
#else
        code = NetworkMapStore.shared.countryCode(for: address)
#endif
        return code.map { Locale.autoupdatingCurrent.localizedString(forRegionCode: $0) ?? $0 }
    }
}

private struct DecisionCell: View {
    let node: MonitorHierarchyNode

    private var aggregate: MonitorAggregate { node.aggregate }

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.xs) {
            RiftDecisionBadge(decision: aggregate.decision)
            Text(label).lineLimit(1)
        }
    }

    private var label: String {
        if let futureChange { return futureChange }
        return aggregate.decision == .mixed ? "\(aggregate.denied) blocked" : aggregate.decision.label
    }

    /// Says when today's rules differ from what this row recorded.
    private var futureChange: String? {
        switch node.ruleCoverage.currentAction {
        case .deny where aggregate.denied == 0: "Blocked from now on"
        case .allow where aggregate.denied > 0: "Allowed from now on"
        default: nil
        }
    }
}

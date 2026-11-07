import RiftControl
import RiftCore
import SwiftUI

/// Every connection in a table with columns, shown when the connection panel
/// is expanded. Replaces the old Activity page.
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
                        Text(node.title).lineLimit(1).truncationMode(.middle)
                    }
                    if let subtitle = node.subtitle {
                        Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(monitorCoverageLabel(node.ruleCoverage.state))
            }
            .width(min: 220, ideal: 340)
            TableColumn("Country") { node in
                Text(countryName(for: node) ?? "—")
                    .foregroundStyle(countryName(for: node) == nil ? .tertiary : .primary)
                    .lineLimit(1)
            }
            .width(min: 70, ideal: 120)
            TableColumn("Decision") { node in
                DecisionCell(aggregate: node.aggregate)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Sent") { node in
                RiftBytesText(bytes: node.aggregate.bytesOutbound, partial: node.aggregate.coverage != .complete)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 84)
            TableColumn("Received") { node in
                RiftBytesText(bytes: node.aggregate.bytesInbound, partial: node.aggregate.coverage != .complete)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 84)
            TableColumn("Connections") { node in
                Text(RiftFormat.count(node.aggregate.flowCount))
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 84)
            TableColumn("Last Seen") { node in
                Text(Self.relativeFormatter.localizedString(for: node.aggregate.lastSeen, relativeTo: feed.now))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 80, ideal: 110)
        }
        .scrollContentBackground(.hidden)
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
                ContentUnavailableView(
                    feed.query.search.isEmpty ? "No Connections" : "No Matches",
                    systemImage: feed.query.search.isEmpty ? "network" : "magnifyingglass"
                )
            }
        }
    }

    @MainActor private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    private func row(for node: MonitorHierarchyNode) -> MonitorEventRow? {
        (node.eventID ?? node.ruleSeedEventID).flatMap { feed.rowLookup[$0] }
    }

    /// The destination country, for nodes that have a single destination.
    private func countryName(for node: MonitorHierarchyNode) -> String? {
        guard node.kind != .application, node.kind != .helper,
              let address = row(for: node)?.event.flow.destinationEndpoint?.address else { return nil }
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
    let aggregate: MonitorAggregate

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.xs) {
            RiftDecisionBadge(decision: aggregate.decision)
            Text(label).lineLimit(1)
        }
    }

    private var label: String {
        if aggregate.denied > 0, aggregate.allowed > 0 { return "\(aggregate.denied) blocked" }
        return aggregate.decision.label
    }
}

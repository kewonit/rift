import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

/// Details and decisions for the selected connection.
struct ConnectionInspectorView: View {
    let node: MonitorHierarchyNode
    let row: MonitorEventRow?
    let applyingEventID: String?
    let artworkStore: ApplicationArtworkStore
    let apply: (FilterAction) -> Void
    let showRules: () -> Void
    var canDecide = false

    var body: some View {
        ScrollView {
            content
                .padding(RiftDesign.Spacing.l)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.m) {
            header
            if canDecide {
                HStack(spacing: 8) {
                    Button { apply(.allow) } label: {
                        Label("Allow…", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    Button { apply(.deny) } label: {
                        Label("Block…", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                }
                .controlSize(.large)
                .disabled(
                    applyingEventID.map(node.eventIDs.contains) ?? false
                        || monitorCoveragePending(node.ruleCoverage.state)
                )
                .help(monitorCoveragePending(node.ruleCoverage.state)
                    ? "Waiting for the filter to apply your last rule change" : "")
            }
            VStack(alignment: .leading, spacing: 7) {
                RiftPropertyRow(title: "Connections") { Text("\(node.aggregate.flowCount)").monospacedDigit() }
                RiftPropertyRow(title: "Rule") {
                    Text(node.ruleCoverage.winningRuleSummary ?? monitorCoverageLabel(node.ruleCoverage.state))
                        .multilineTextAlignment(.trailing)
                }
                if let row {
                    if node.kind != .application, node.kind != .helper {
                        RiftPropertyRow(title: "App") {
                            ApplicationNameText(
                                identity: row.event.flow.sourceAppIdentity ?? row.event.flow.sourceProcessIdentity,
                                fallback: MonitorQuery.applicationLabel(row),
                                artworkStore: artworkStore
                            )
                            .lineLimit(1)
                        }
                    }
                    RiftPropertyRow(title: "Result") { Text(row.event.outcome == .blocked ? "Blocked" : "Allowed") }
                    RiftPropertyRow(title: "Because") { Text(row.event.causeSentence).multilineTextAlignment(.trailing) }
                    if let current = node.ruleCoverage.currentAction {
                        RiftPropertyRow(title: "From now on") { Text(current == .deny ? "Blocked" : "Allowed") }
                    }
                    RiftPropertyRow(title: "Destination") {
                        Text(MonitorQuery.endpointLabel(row)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    RiftPropertyRow(title: "Protocol") { Text(MonitorQuery.protocolLabel(row)) }
                    RiftPropertyRow(title: "Direction") { Text(row.event.flow.direction.rawValue.capitalized) }
                    if let closedAt = row.closedAt {
                        RiftPropertyRow(title: "Closed") { Text(closedAt.formatted(date: .omitted, time: .shortened)) }
                    }
                }
            }
            Button(node.ruleCoverage.winningRuleID == nil ? "Show Matching Rules" : "Show This Rule", action: showRules)
                .buttonStyle(.link)
                .disabled(node.ruleCoverage.ruleIDs.isEmpty)
                .help(node.ruleCoverage.ruleIDs.isEmpty ? "No rules match this connection" : "")
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            if let identity = node.presentationIdentity {
                ApplicationIdentityIcon(
                    identity: identity,
                    fallbackSystemName: node.kind == .helper ? "gearshape.2" : "app.dashed",
                    size: 28,
                    artworkStore: artworkStore
                )
            }
            VStack(alignment: .leading, spacing: 1) {
                if node.kind == .application || node.kind == .helper {
                    ApplicationNameText(
                        identity: node.presentationIdentity, fallback: node.title, artworkStore: artworkStore
                    )
                    .font(.headline)
                } else {
                    Text(node.title).font(.headline)
                }
                if let subtitle = node.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

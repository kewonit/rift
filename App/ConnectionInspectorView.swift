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
    var ruleSummaries: ([UUID]) async -> [(id: UUID, text: String)] = { _ in [] }
    var canDecide = false
    @State private var appliedRules: [(id: UUID, text: String)] = []

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
            if let identity = row.flatMap({ $0.event.flow.sourceProcessIdentity ?? $0.event.flow.sourceAppIdentity }) {
                RiftPropertyRow(title: "Signed by") {
                    Text(ConnectionAlertFacts.signerLabel(for: identity)).multilineTextAlignment(.trailing)
                }
            }
            if let row {
                ConnectionExplanationView(
                    identity: row.event.flow.sourceProcessIdentity ?? row.event.flow.sourceAppIdentity,
                    fallbackName: MonitorQuery.applicationLabel(row),
                    host: row.event.flow.observedHostname?.ascii
                        ?? row.event.flow.remoteEndpoint?.address.description
                )
            }
            if !appliedRules.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rules that apply").font(.caption).foregroundStyle(.secondary)
                    ForEach(appliedRules, id: \.id) { rule in
                        Text(rule.text).font(.callout).lineLimit(2).textSelection(.enabled)
                    }
                }
            }
            Button(node.ruleCoverage.winningRuleID == nil ? "Show Matching Rules" : "Show This Rule", action: showRules)
                .buttonStyle(.link)
                .disabled(node.ruleCoverage.ruleIDs.isEmpty)
                .help(node.ruleCoverage.ruleIDs.isEmpty ? "No rules match this connection" : "")
        }
        .task(id: node.ruleCoverage.ruleIDs) {
            // The deciding rule comes first.
            let winner = node.ruleCoverage.winningRuleID
            let others = node.ruleCoverage.ruleIDs.subtracting(winner.map { [$0] } ?? []).sorted { $0.uuidString < $1.uuidString }
            appliedRules = await ruleSummaries((winner.map { [$0] } ?? []) + others.prefix(9))
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
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
        }
    }
}

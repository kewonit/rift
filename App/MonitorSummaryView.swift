import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

struct MonitorSummaryView: View {
    let summary: MonitorSummarySnapshot
    let selectedNode: MonitorHierarchyNode?
    let selectedRow: MonitorEventRow?
    let applyingEventID: String?
    let artworkStore: ApplicationArtworkStore
    let apply: (FilterAction, MonitorHierarchyNode) -> Void
    let showRules: () -> Void
    var canDecide = false
    var isMinimal = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let selectedNode {
                    selection(node: selectedNode, row: selectedRow)
                    Divider()
                }
                header
                section("Traffic") {
                    RiftPropertyRow(title: "Sent", symbol: "arrow.up") {
                        Text(format(summary.sent)).monospacedDigit()
                    }
                    .help("Sent totals are counted when connections close.")
                    .accessibilityValue(accessible(summary.sent))
                    RiftPropertyRow(title: "Received", symbol: "arrow.down") {
                        Text(format(summary.received)).monospacedDigit()
                    }
                    .help("Received totals are counted when connections close.")
                    .accessibilityValue(accessible(summary.received))
                }
                section("Connections") {
                    countRow("Blocked", summary.denied, "xmark.circle")
                    countRow("No rule", summary.unresolved, "minus.circle")
                    countRow("Incoming", summary.incoming, "arrow.down.left")
                }
                rankedSection("Top Apps", values: summary.topApplications, showsApplicationIcons: true)
                rankedSection("Top Destinations", values: summary.topDestinations)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Summary").font(.title3.weight(.semibold))
            Text(isMinimal ? "Recent connections only" : summaryCountLabel)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(summary.isComplete
                    ? "Counts include all matching activity."
                    : "Some activity is missing, so these are minimum counts.")
        }
    }

    private var summaryCountLabel: String {
        let prefix = summary.isComplete ? "" : "≥"
        let apps = summary.processCount == 1 ? "app" : "apps"
        let destinations = summary.destinationCount == 1 ? "destination" : "destinations"
        return "\(prefix)\(summary.processCount) \(apps) · \(prefix)\(summary.destinationCount) \(destinations)"
    }

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RiftSectionHeader(title)
            content()
        }
    }

    private func countRow(_ label: String, _ value: Int, _ symbol: String) -> some View {
        RiftPropertyRow(title: label, symbol: symbol) {
            Text("\(value)").monospacedDigit()
        }
    }

    private func rankedSection(
        _ title: String,
        values: [MonitorRankedItem],
        showsApplicationIcons: Bool = false
    ) -> some View {
        section(title) {
            if values.isEmpty {
                Text("None yet").font(.callout).foregroundStyle(.tertiary)
            } else {
                ForEach(values) { value in
                    HStack(spacing: 8) {
                        if showsApplicationIcons {
                            ApplicationIdentityIcon(
                                identity: value.presentationIdentity,
                                fallbackSystemName: "app.dashed",
                                size: 16,
                                artworkStore: artworkStore
                            )
                        }
                        if showsApplicationIcons {
                            ApplicationNameText(
                                identity: value.presentationIdentity,
                                fallback: value.label,
                                artworkStore: artworkStore
                            )
                            .lineLimit(1)
                        } else {
                            Text(value.label).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer(minLength: 8)
                        Text("\(value.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                    .accessibilityValue(flowCountLabel(value.count))
                }
            }
        }
    }

    private func flowCountLabel(_ count: Int) -> String {
        count == 1 ? "1 connection" : "\(count) connections"
    }

    private func selection(
        node: MonitorHierarchyNode,
        row: MonitorEventRow?
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            selectionHeader(node)
            if canDecide {
                HStack(spacing: 8) {
                    Button { apply(.allow, node) } label: {
                        Label("Allow…", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    Button { apply(.deny, node) } label: {
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

    private func selectionHeader(_ node: MonitorHierarchyNode) -> some View {
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

    private func format(_ total: ReportedByteTotal) -> String {
        guard let value = total.value else { return "—" }
        let formatted = ByteCountFormatter.string(
            fromByteCount: Int64(clamping: value), countStyle: .file
        )
        return total.isPartial ? "≥\(formatted)" : formatted
    }

    private func accessible(_ total: ReportedByteTotal) -> String {
        guard total.value != nil else { return "not reported" }
        return total.isPartial ? "partial, at least \(format(total).dropFirst())" : format(total)
    }
}

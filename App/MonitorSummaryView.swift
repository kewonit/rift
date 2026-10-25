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
                    countRow("Denied", summary.denied, "xmark.circle")
                    countRow("By default", summary.unresolved, "questionmark.circle")
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
                        Text(value.label).lineLimit(1).truncationMode(.middle)
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
            if let row, MonitorExactRuleSeed.make(from: row) != nil {
                HStack(spacing: 8) {
                    Button { apply(.allow, node) } label: {
                        Label("Allow", systemImage: "checkmark").frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Allow this connection")
                    Button { apply(.deny, node) } label: {
                        Label("Deny", systemImage: "xmark").frame(maxWidth: .infinity)
                    }
                    .accessibilityLabel("Deny this connection")
                }
                .controlSize(.large)
                .disabled(
                    applyingEventID == node.ruleSeedEventID
                        || monitorCoveragePending(node.ruleCoverage.state)
                )
            }
            VStack(alignment: .leading, spacing: 7) {
                RiftPropertyRow(title: "Connections") { Text("\(node.aggregate.flowCount)").monospacedDigit() }
                RiftPropertyRow(title: "Rule") { Text(monitorCoverageLabel(node.ruleCoverage.state)).multilineTextAlignment(.trailing) }
                if let row {
                    RiftPropertyRow(title: "Decision") { Text(decisionLabel(row.event.action)) }
                    RiftPropertyRow(title: "Reason") { Text(reasonLabel(row.event.reason)).multilineTextAlignment(.trailing) }
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
            Button("Show Matching Rules", action: showRules)
                .buttonStyle(.link)
                .disabled(node.ruleCoverage.ruleIDs.isEmpty)
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
                Text(node.title).font(.headline)
                if let subtitle = node.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func decisionLabel(_ action: FilterAction) -> String {
        switch action {
        case .allow: "Allowed"
        case .deny: "Denied"
        case .ask: "Asked"
        }
    }

    private func reasonLabel(_ reason: RuntimeEventReason) -> String {
        switch reason {
        case .concreteDecision: "Matched a rule"
        case .unmatchedModeFallback: "No rule matched, so the mode decided"
        case .promptUnavailableFallback: "Alert couldn’t be shown, so the default was used"
        case .promptDeadlineFallback: "Alert timed out, so the default was used"
        case .noActivePolicy: "No rules were active"
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

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
    let hideSummary: () -> Void
    var isMinimal = false
    @State private var connectionsExpanded = true
    @State private var statisticsExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                metricChips
                DisclosureGroup("Connections", isExpanded: $connectionsExpanded) {
                    VStack(spacing: 8) {
                        metricRow("Denied", summary.denied, "xmark.circle")
                        metricRow("By default", summary.unresolved, "questionmark.circle")
                        metricRow("Incoming", summary.incoming, "arrow.turn.down.left")
                    }
                    .padding(.top, 8)
                }
                .monitorSectionStyle()

                DisclosureGroup("Statistics", isExpanded: $statisticsExpanded) {
                    VStack(alignment: .leading, spacing: 12) {
                        rankedSection(
                            "Top Apps",
                            values: summary.topApplications,
                            showsApplicationIcons: true
                        )
                        rankedSection("Top Destinations", values: summary.topDestinations)
                    }
                    .padding(.top, 9)
                }
                .monitorSectionStyle()

                if let selectedNode {
                    Divider()
                    selection(node: selectedNode, row: selectedRow)
                }
            }
            .padding(12)
        }
        .background(.bar)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Button(action: hideSummary) {
                Image(systemName: "line.3.horizontal")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Hide Summary")
            .help("Hide summary")
            VStack(alignment: .leading, spacing: 1) {
                Text("Summary").font(.title2.weight(.semibold))
                if isMinimal {
                    Text("Recent connections only")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(summaryCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(summary.isComplete
                        ? "Counts include all matching activity."
                        : "Some activity is missing, so these are minimum counts.")
            }
        }
    }

    private var summaryCountLabel: String {
        let prefix = summary.isComplete ? "" : "≥"
        let apps = summary.processCount == 1 ? "app" : "apps"
        let destinations = summary.destinationCount == 1 ? "destination" : "destinations"
        return "\(prefix)\(summary.processCount) \(apps), \(prefix)\(summary.destinationCount) \(destinations)"
    }

    private var metricChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                summaryChip("Sent", summary.sent, "arrow.up", RiftDesign.trafficSent)
                summaryChip("Received", summary.received, "arrow.down", .blue)
            }
            VStack(spacing: 6) {
                summaryChip("Sent", summary.sent, "arrow.up", RiftDesign.trafficSent)
                summaryChip("Received", summary.received, "arrow.down", .blue)
            }
        }
    }

    private func summaryChip(
        _ title: String,
        _ total: ReportedByteTotal,
        _ symbol: String,
        _ color: Color
    ) -> some View {
        HStack {
            Image(systemName: symbol)
            Text(format(total))
                .font(.headline.monospacedDigit())
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, minHeight: 31)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(title), \(accessible(total))")
        .help("\(title) totals are counted when connections close.")
    }

    private func metricRow(_ label: String, _ value: Int, _ symbol: String) -> some View {
        HStack {
            Image(systemName: symbol).frame(width: 20).foregroundStyle(.secondary)
            Text(label)
            Spacer()
            Text("\(value)").monospacedDigit()
        }
    }

    private func rankedSection(
        _ title: String,
        values: [MonitorRankedItem],
        showsApplicationIcons: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            if values.isEmpty {
                Text("—").foregroundStyle(.secondary)
            } else {
                ForEach(values) { value in
                    HStack(alignment: .firstTextBaseline) {
                        if showsApplicationIcons {
                            ApplicationIdentityIcon(
                                identity: value.presentationIdentity,
                                fallbackSystemName: "app.dashed",
                                size: 18,
                                artworkStore: artworkStore
                            )
                        }
                        Text(value.label).lineLimit(1)
                        Spacer()
                        Text(flowCountLabel(value.count))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
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
        VStack(alignment: .leading, spacing: 9) {
            selectionHeader(node)
            LabeledContent("Connections", value: "\(node.aggregate.flowCount)")
            LabeledContent("Rule", value: monitorCoverageLabel(node.ruleCoverage.state))
            if let row, MonitorExactRuleSeed.make(from: row) != nil {
                ControlGroup {
                    Button("Allow") { apply(.allow, node) }
                        .accessibilityLabel("Allow this connection")
                    Button("Deny") { apply(.deny, node) }
                        .accessibilityLabel("Deny this connection")
                }
                .controlSize(.small)
                .disabled(
                    applyingEventID == node.ruleSeedEventID
                        || monitorCoveragePending(node.ruleCoverage.state)
                )
            }
            if let row {
                LabeledContent("Protocol", value: MonitorQuery.protocolLabel(row))
                LabeledContent("Direction", value: row.event.flow.direction.rawValue.capitalized)
                LabeledContent("Decision", value: decisionLabel(row.event.action))
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    if let row {
                        LabeledContent("Application", value: MonitorQuery.applicationLabel(row))
                        LabeledContent("Destination", value: MonitorQuery.endpointLabel(row))
                        LabeledContent("Reason", value: reasonLabel(row.event.reason))
                        if let policy = row.event.policy {
                            LabeledContent("Rules version", value: "\(policy.generation)")
                        }
                        if let closedAt = row.closedAt {
                            LabeledContent("Closed", value: closedAt.formatted())
                        }
                    }
                }
                .font(.caption)
                .padding(.top, 6)
            }
            Button("Show Matching Rules", action: showRules)
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

private extension View {
    func monitorSectionStyle() -> some View {
        padding(8)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
    }
}

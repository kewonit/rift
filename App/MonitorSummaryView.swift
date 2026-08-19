import RiftControl
import RiftCore
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
    @State private var connectionsExpanded = true
    @State private var statisticsExpanded = true

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
#if DEBUG
                if MonitorFixtureBytePresentation.isEnabled {
                    metricChips
                }
#endif
                DisclosureGroup("Connections", isExpanded: $connectionsExpanded) {
                    VStack(spacing: 8) {
                        metricRow("Denied", summary.denied, "xmark.circle")
                        metricRow("Unresolved", summary.unresolved, "questionmark.circle")
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
            .help("Hide Summary")
            VStack(alignment: .leading, spacing: 1) {
                Text("Summary").font(.title2.weight(.semibold))
                Text(summaryCountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(summary.isComplete
                        ? "Counts cover the complete matching range."
                        : "Counts are minimums from the available matching activity.")
            }
        }
    }

    private var summaryCountLabel: String {
        let prefix = summary.isComplete ? "" : "≥"
        return "\(prefix)\(summary.processCount) processes, \(prefix)\(summary.destinationCount) destinations"
    }

#if DEBUG
    private var metricChips: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                summaryChip("Sent", summary.sent, "arrow.up", .purple)
                summaryChip("Received", summary.received, "arrow.down", .blue)
            }
            VStack(spacing: 6) {
                summaryChip("Sent", summary.sent, "arrow.up", .purple)
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
            if total.isPartial {
                Text("Partial").font(.caption2)
            }
        }
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, minHeight: 31)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityLabel("\(title), \(accessible(total))")
        .help("\(title) is reported when connections close")
    }
#endif

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
        count == 1 ? "1 flow" : "\(count) flows"
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
                        .accessibilityLabel("Allow exact connection")
                    Button("Deny") { apply(.deny, node) }
                        .accessibilityLabel("Deny exact connection")
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
                LabeledContent("Decision", value: row.event.action.rawValue.capitalized)
            }
            DisclosureGroup("Details") {
                VStack(alignment: .leading, spacing: 6) {
                    if let row {
                        LabeledContent("Application", value: MonitorQuery.applicationLabel(row))
                        LabeledContent("Destination", value: MonitorQuery.endpointLabel(row))
                        LabeledContent("Reason", value: row.event.reason.rawValue)
                        if let policy = row.event.policy {
                            LabeledContent("Policy generation", value: "\(policy.generation)")
                        }
                        if let closedAt = row.closedAt {
                            LabeledContent("Closed", value: closedAt.formatted())
                        }
                    }
                }
                .font(.caption)
                .padding(.top, 6)
            }
            Button("Show Corresponding Rules", action: showRules)
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

#if DEBUG
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
#endif
}

private extension View {
    func monitorSectionStyle() -> some View {
        padding(8)
            .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 7))
    }
}

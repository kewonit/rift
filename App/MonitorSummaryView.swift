import RiftControl
import SwiftUI

/// The inspector with nothing selected: what the connections in the list add
/// up to.
struct MonitorSummaryView: View {
    let summary: MonitorSummary
    let isViewingPast: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: RiftDesign.Spacing.m) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Summary").font(.headline)
                    Text(isViewingPast ? "Connections in the list, for the time shown" : "Connections in the list")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if summary.connections == 0 {
                    Text("No connections to sum up.")
                        .foregroundStyle(.secondary)
                } else {
                    counts
                    list("Most Active Apps", summary.topApps)
                    list("Most Active Hostnames", summary.topHostnames)
                    list("Most Active Countries", summary.topCountries)
                }
            }
            .padding(RiftDesign.Spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var counts: some View {
        VStack(alignment: .leading, spacing: 7) {
            row("Connections", summary.connections)
            row("Apps", summary.apps)
            row("Hostnames", summary.hostnames)
            row("Blocked", summary.blocked)
            row("No rule applied", summary.undecided)
            row("Incoming", summary.incoming)
            RiftPropertyRow(title: "Received") { RiftBytesText(bytes: summary.bytesInbound) }
            RiftPropertyRow(title: "Sent") { RiftBytesText(bytes: summary.bytesOutbound) }
        }
    }

    private func row(_ title: String, _ value: Int) -> some View {
        RiftPropertyRow(title: title) { Text(RiftFormat.count(value)).monospacedDigit() }
    }

    @ViewBuilder
    private func list(_ title: String, _ entries: [MonitorSummary.Entry]) -> some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                ForEach(entries) { entry in
                    HStack(spacing: RiftDesign.Spacing.s) {
                        Text(entry.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: RiftDesign.Spacing.s)
                        Text(detail(entry)).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func detail(_ entry: MonitorSummary.Entry) -> String {
        let count = RiftFormat.count(entry.connections)
        return entry.blocked == 0 ? count : "\(count), \(RiftFormat.count(entry.blocked)) blocked"
    }
}

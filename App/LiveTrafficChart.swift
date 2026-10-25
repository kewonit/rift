import RiftControl
import SwiftUI

struct LiveTrafficChart: View {
    let snapshot: LiveTrafficSnapshot
    @Binding var query: MonitorQueryState
    let now: Date
    var isMinimal = false


    private let ranges: [MonitorTimeFilter] = [
        .twoMinutes, .tenMinutes, .hour, .fiveHours, .day,
        .threeDays, .week, .month, .thirtyDays, .all,
    ]

    var body: some View {
        VStack(spacing: 7) {
            totals
            chart
            if isMinimal {
                Text("Up to \(ControlPlaneController.minimalFlowLimit) recent connections · 5 minutes · Not saved")
                    .font(.caption2).foregroundStyle(.secondary)
            } else { rangeControls }
        }
        .padding(10)
        .background(.bar)
        .accessibilityElement(children: .contain)
    }

    private var totals: some View {
        HStack(spacing: 8) {
            TrafficTotal(
                title: "Sent",
                systemImage: "arrow.up",
                bytes: snapshot.sent,
                partial: snapshot.partial,
                color: RiftDesign.trafficSent
            )
            TrafficTotal(
                title: "Received",
                systemImage: "arrow.down",
                bytes: snapshot.received,
                partial: snapshot.partial,
                color: .blue
            )
        }
    }

    private var chart: some View {
        Canvas { context, size in
            let middle = size.height / 2
            let width = max(2, size.width / CGFloat(max(snapshot.bins.count, 1)))
            let maximum = max(1, snapshot.maximum)
            for index in snapshot.bins.indices {
                let x = CGFloat(index) * width
                let background = CGRect(
                    x: x + 1,
                    y: 0,
                    width: max(1, width - 2),
                    height: size.height
                )
                context.fill(
                    Path(roundedRect: background, cornerRadius: 3),
                    with: .color(Color.secondary.opacity(0.10))
                )
                let bin = snapshot.bins[index]
                let sentHeight = CGFloat(bin.sent) / CGFloat(maximum) * (middle - 2)
                let receivedHeight = CGFloat(bin.received) / CGFloat(maximum) * (middle - 2)
                context.fill(
                    Path(roundedRect: CGRect(
                        x: x + 1,
                        y: middle - sentHeight,
                        width: max(1, width - 2),
                        height: sentHeight
                    ), cornerRadius: 2),
                    with: .color(RiftDesign.trafficSent.opacity(0.88))
                )
                context.fill(
                    Path(roundedRect: CGRect(
                        x: x + 1,
                        y: middle,
                        width: max(1, width - 2),
                        height: receivedHeight
                    ), cornerRadius: 2),
                    with: .color(Color.blue.opacity(0.86))
                )
            }
        }
        .frame(height: 82)
        .accessibilityElement()
        .accessibilityLabel(isMinimal ? "Traffic from recent connections" : "Traffic in the selected time range")
        .accessibilityValue(accessibilitySummary)
    }

    private var rangeControls: some View {
        HStack(spacing: 5) {
            ControlGroup {
                Button { navigate(.previous) } label: {
                    Label("Previous Range", systemImage: "chevron.left")
                }
                .disabled(!query.canNavigateBackward)
                Button { query.showNow() } label: {
                    Label("Show Now", systemImage: "scope")
                }
                .disabled(query.isLiveTimeRange && query.selectedTimeRange == nil)
                Button { zoom(-1) } label: {
                    Label("Shorter Range", systemImage: "minus.magnifyingglass")
                }
                .disabled(rangeIndex <= 0)
            }
            .labelStyle(.iconOnly)

            Picker("Time range", selection: timeFilter) {
                ForEach(ranges) { value in Text(value.rawValue).tag(value) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity)
            .accessibilityValue(displayedRangeLabel)

            ControlGroup {
                Button { zoom(1) } label: {
                    Label("Longer Range", systemImage: "plus.magnifyingglass")
                }
                .disabled(rangeIndex >= ranges.count - 1)
                Button { navigate(.next) } label: {
                    Label("Next Range", systemImage: "chevron.right")
                }
                .disabled(!query.canNavigateForward)
                Button { query.showNow() } label: {
                    Label("Jump to Now", systemImage: "chevron.forward.2")
                }
                .disabled(query.isLiveTimeRange && query.selectedTimeRange == nil)
            }
            .labelStyle(.iconOnly)
        }
        .controlSize(.small)
    }

    private var timeFilter: Binding<MonitorTimeFilter> {
        Binding(
            get: { query.time },
            set: { query.selectTimeFilter($0) }
        )
    }

    private var rangeIndex: Int { ranges.firstIndex(of: query.time) ?? 0 }

    private var displayedRangeLabel: String {
        if query.time == .all { return "All saved activity" }
        if query.isLiveTimeRange { return "Last " + query.time.rawValue.lowercased() }
        guard let window = query.baseTimeWindow(now: now),
              let start = window.start, let end = window.end else { return query.time.rawValue }
        return start.formatted(date: .abbreviated, time: .shortened)
            + " – " + end.formatted(date: .abbreviated, time: .shortened)
    }

    private var accessibilitySummary: String {
        let partial = snapshot.partial ? ", some totals missing" : ""
        return "Sent \(byteLabel(snapshot.sent)); received \(byteLabel(snapshot.received))\(partial)"
    }

    private func zoom(_ delta: Int) {
        let target = min(max(rangeIndex + delta, 0), ranges.count - 1)
        guard target != rangeIndex else { return }
        query.selectTimeFilter(ranges[target])
    }

    private func navigate(_ direction: MonitorTimeNavigation) {
        query.navigateTime(direction, now: now)
    }


}

private struct TrafficTotal: View {
    let title: String
    let systemImage: String
    let bytes: UInt64
    let partial: Bool
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
            Text(title).font(.caption.weight(.semibold))
            Spacer(minLength: 3)
            Text((partial ? "≥" : "") + byteLabel(bytes))
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 30)
        .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 7))
        .accessibilityElement(children: .combine)
    }
}

struct LiveTrafficBin: Sendable, Hashable {
    var sent: UInt64 = 0
    var received: UInt64 = 0
}

struct LiveTrafficSnapshot: Sendable, Hashable {
    let bins: [LiveTrafficBin]
    let sent: UInt64
    let received: UInt64
    let partial: Bool

    static let empty = LiveTrafficSnapshot(
        bins: Array(repeating: LiveTrafficBin(), count: 30),
        sent: 0,
        received: 0,
        partial: true
    )

    var maximum: UInt64 {
        bins.reduce(0) { max($0, max($1.sent, $1.received)) }
    }

    static func make(
        rows: [MonitorEventRow],
        bounds: (start: Date, end: Date)?
    ) -> LiveTrafficSnapshot {
        let count = 30
        var bins = Array(repeating: LiveTrafficBin(), count: count)
        guard let bounds, bounds.start < bounds.end else {
            return LiveTrafficSnapshot(bins: bins, sent: 0, received: 0, partial: true)
        }
        let duration = bounds.end.timeIntervalSince(bounds.start)
        var sent: UInt64 = 0
        var received: UInt64 = 0
        var partial = false
        for row in rows where row.event.occurredAt >= bounds.start && row.event.occurredAt < bounds.end {
            let progress = row.event.occurredAt.timeIntervalSince(bounds.start) / duration
            let index = min(max(Int(progress * Double(count)), 0), count - 1)
            if let value = row.bytesOutbound {
                sent = adding(sent, value)
                bins[index].sent = adding(bins[index].sent, value)
            } else { partial = true }
            if let value = row.bytesInbound {
                received = adding(received, value)
                bins[index].received = adding(bins[index].received, value)
            } else { partial = true }
            if row.coverage != .complete { partial = true }
        }
        return LiveTrafficSnapshot(
            bins: bins, sent: sent, received: received, partial: partial
        )
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }
}

func byteLabel(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
}

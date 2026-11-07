import Charts
import RiftControl
import SwiftUI

/// Sent bytes above a hairline and received bytes below it, one bar per bin.
struct TrafficBars: View {
    let snapshot: LiveTrafficSnapshot

    var body: some View {
        Canvas { context, size in
            let middle = (size.height / 2).rounded()
            let count = max(snapshot.bins.count, 1)
            let slot = size.width / CGFloat(count)
            let barWidth = max(2, slot * 0.62)
            let maximum = CGFloat(max(1, snapshot.maximum))
            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: middle))
            baseline.addLine(to: CGPoint(x: size.width, y: middle))
            context.stroke(baseline, with: .color(.secondary.opacity(0.25)), lineWidth: 0.5)
            for (index, bin) in snapshot.bins.enumerated() {
                let x = CGFloat(index) * slot + (slot - barWidth) / 2
                let sent = CGFloat(bin.sent) / maximum * (middle - 1)
                let received = CGFloat(bin.received) / maximum * (middle - 1)
                if sent > 0 {
                    context.fill(
                        Path(roundedRect: CGRect(x: x, y: middle - max(sent, 1.5), width: barWidth, height: max(sent, 1.5)),
                             cornerRadius: min(2, barWidth / 2)),
                        with: .color(RiftDesign.trafficSent)
                    )
                }
                if received > 0 {
                    context.fill(
                        Path(roundedRect: CGRect(x: x, y: middle, width: barWidth, height: max(received, 1.5)),
                             cornerRadius: min(2, barWidth / 2)),
                        with: .color(RiftDesign.trafficReceived)
                    )
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Traffic over time")
        .accessibilityValue(
            "Sent \(RiftFormat.bytes(snapshot.sent)), received \(RiftFormat.bytes(snapshot.received))"
                + (snapshot.partial ? ", some sizes missing" : "")
        )
    }
}

/// Allowed, denied and by-default decisions per time bucket. Drag to show a
/// time range; hover to read a bucket.
struct DecisionBars: View {
    @Environment(\.calendar) private var calendar
    let snapshot: DecisionBucketSnapshot
    @Binding var query: MonitorQueryState
    let now: Date
    let selectable: Bool
    @Binding var hovered: DecisionBucket?

    var body: some View {
        Chart {
            if let selection = query.selectedTimeRange {
                RectangleMark(
                    xStart: .value("Selection start", selection.lowerBound),
                    xEnd: .value("Selection end", selection.upperBound)
                )
                .foregroundStyle(Color.accentColor.opacity(0.14))
            }
            if let start = baseWindow?.start {
                RuleMark(x: .value("Range start", start)).foregroundStyle(.clear)
            }
            if let end = baseWindow?.end {
                RuleMark(x: .value("Range end", end)).foregroundStyle(.clear)
            }
            ForEach(snapshot.buckets) { bucket in
                BarMark(x: .value("Time", bucket.start), y: .value("Allowed", bucket.allowed), width: .fixed(5))
                    .foregroundStyle(by: .value("Result", RiftDecision.allowed.label))
                BarMark(x: .value("Time", bucket.start), y: .value("Blocked", bucket.denied), width: .fixed(5))
                    .foregroundStyle(by: .value("Result", RiftDecision.denied.label))
                BarMark(x: .value("Time", bucket.start), y: .value("No rule", bucket.unresolved), width: .fixed(5))
                    .foregroundStyle(by: .value("Result", RiftDecision.byDefault.label))
            }
            if let hovered {
                RuleMark(x: .value("Hovered time", hovered.start))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartForegroundStyleScale([
            RiftDecision.allowed.label: RiftDecision.allowed.color,
            RiftDecision.denied.label: RiftDecision.denied.color,
            RiftDecision.byDefault.label: RiftDecision.byDefault.color,
        ])
        .chartLegend(.hidden)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2)
                            .onChanged { updateSelection($0, proxy: proxy, geometry: geometry) }
                    )
                    .onContinuousHover { updateHover($0, proxy: proxy, geometry: geometry) }
            }
        }
        .onChange(of: snapshot.buckets) { _, updated in
            if let hovered, !updated.contains(where: { $0.id == hovered.id }) { self.hovered = nil }
        }
        .accessibilityLabel("Decisions over time")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint(selectable ? "Drag to show activity from a time range." : "")
    }

    private var baseWindow: MonitorTimeWindow? {
        query.baseTimeWindow(now: now, calendar: calendar)
    }

    private var accessibilitySummary: String {
        let allowed = snapshot.buckets.reduce(0) { $0 + $1.allowed }
        let denied = snapshot.buckets.reduce(0) { $0 + $1.denied }
        let unresolved = snapshot.buckets.reduce(0) { $0 + $1.unresolved }
        let suffix = snapshot.coverage == .complete ? "" : ", some history missing"
        return "\(allowed) allowed, \(denied) blocked, \(unresolved) with no rule\(suffix)"
    }

    private func updateHover(_ phase: HoverPhase, proxy: ChartProxy, geometry: GeometryProxy) {
        switch phase {
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else { hovered = nil; return }
            let frame = geometry[plotFrame]
            guard frame.contains(location),
                  let date: Date = proxy.value(atX: location.x - frame.minX) else { hovered = nil; return }
            hovered = snapshot.buckets.min {
                abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
            }
        case .ended:
            hovered = nil
        }
    }

    private func updateSelection(_ value: DragGesture.Value, proxy: ChartProxy, geometry: GeometryProxy) {
        guard selectable,
              let start = date(at: value.startLocation.x, proxy: proxy, geometry: geometry),
              let end = date(at: value.location.x, proxy: proxy, geometry: geometry) else { return }
        query.selectTimeRange(min(start, end)...max(start, end), now: now, calendar: calendar)
        hovered = nil
    }

    private func date(at x: CGFloat, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        return proxy.value(atX: min(max(x - frame.minX, 0), frame.width))
    }
}

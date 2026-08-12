import AbyssControl
import Charts
import SwiftUI

struct DecisionChartView: View {
    @Environment(\.calendar) private var calendar
    let controlPlane: ControlPlaneController
    @Binding var query: MonitorQueryState
    let now: Date
    @State private var buckets: [DecisionBucket] = []
    @State private var coverage: HistoryCoverage = .gap
    @State private var refreshFailed = false
    @State private var hoveredBucket: DecisionBucket?

    var body: some View {
        VStack(spacing: 5) {
            chart
            statusRow
            controlsRow
        }
        .task(id: reloadID) { await reload() }
    }

    private var chart: some View {
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
            ForEach(buckets) { bucket in
                BarMark(
                    x: .value("Time", bucket.start),
                    y: .value("Allowed", bucket.allowed),
                    width: .fixed(7)
                )
                .foregroundStyle(by: .value("Result", "Allowed"))
                BarMark(
                    x: .value("Time", bucket.start),
                    y: .value("Denied", bucket.denied),
                    width: .fixed(7)
                )
                .foregroundStyle(by: .value("Result", "Denied"))
                BarMark(
                    x: .value("Time", bucket.start),
                    y: .value("Unresolved", bucket.unresolved),
                    width: .fixed(7)
                )
                .foregroundStyle(by: .value("Result", "Unresolved"))
            }
            if let hoveredBucket {
                RuleMark(x: .value("Hovered time", hoveredBucket.start))
                    .foregroundStyle(.secondary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartForegroundStyleScale([
            "Allowed": Color.accentColor,
            "Denied": Color.red,
            "Unresolved": Color.orange,
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
                            .onChanged { value in
                                updateSelection(value, proxy: proxy, geometry: geometry)
                            }
                    )
                    .onContinuousHover { phase in
                        updateHover(phase, proxy: proxy, geometry: geometry)
                    }
            }
        }
        .frame(height: 88)
        .accessibilityLabel("Delivered decisions in the displayed time range")
        .accessibilityValue(accessibilitySummary)
        .accessibilityHint("Independent of search and map filters. Drag to filter Monitor by time.")
    }

    private var statusRow: some View {
        HStack(spacing: 5) {
            Text("Decisions")
                .font(.caption)
                .foregroundStyle(.secondary)
            if coverage != .complete || refreshFailed {
                Text("Partial")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Decision history is partial")
            }
            if refreshFailed {
                Text("Couldn’t refresh")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let hoveredBucket {
                Text(hoverLabel(hoveredBucket))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if query.selectedTimeRange != nil {
                Text("Selected range")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var controlsRow: some View {
        HStack(spacing: 5) {
            ControlGroup {
                Button { navigate(.previous) } label: {
                    Label("Previous range", systemImage: "chevron.left")
                }
                .disabled(!query.canNavigateBackward)
                Button { query.showNow(); hoveredBucket = nil } label: {
                    Label("Now", systemImage: "scope")
                }
                .disabled(query.isLiveTimeRange && query.selectedTimeRange == nil)
                Button { navigate(.next) } label: {
                    Label("Next range", systemImage: "chevron.right")
                }
                .disabled(!query.canNavigateForward)
            }
            .labelStyle(.iconOnly)
            if query.selectedTimeRange != nil {
                Button {
                    query.selectTimeRange(nil, now: now, calendar: calendar)
                    hoveredBucket = nil
                } label: {
                    Label("Clear time selection", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
            Picker("Range", selection: timeFilter) {
                ForEach(MonitorTimeFilter.allCases) { value in
                    Text(value.rawValue).tag(value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .controlSize(.small)
    }

    private var timeFilter: Binding<MonitorTimeFilter> {
        Binding(
            get: { query.time },
            set: { query.selectTimeFilter($0); hoveredBucket = nil }
        )
    }

    private var baseWindow: MonitorTimeWindow? {
        query.baseTimeWindow(now: now, calendar: calendar)
    }

    private var accessibilitySummary: String {
        let allowed = buckets.reduce(0) { $0 + $1.allowed }
        let denied = buckets.reduce(0) { $0 + $1.denied }
        let unresolved = buckets.reduce(0) { $0 + $1.unresolved }
        let selection = query.selectedTimeRange == nil ? "" : ", time selection active"
        let suffix = coverage == .complete && !refreshFailed ? "" : ", partial history"
        return "\(allowed) allowed, \(denied) denied, \(unresolved) unresolved\(selection)\(suffix)"
    }

    private var reloadID: String {
        let anchor = query.timeAnchor?.timeIntervalSinceReferenceDate ?? -1
        let liveNow = query.timeAnchor == nil ? now.timeIntervalSinceReferenceDate : 0
        return "\(query.time.rawValue)|\(anchor)|\(liveNow)"
    }

    private func navigate(_ direction: MonitorTimeNavigation) {
        query.navigateTime(direction, now: now, calendar: calendar)
        hoveredBucket = nil
    }

    private func reload() async {
        guard let window = baseWindow,
              let range = window.resolvedBounds(
                defaultStart: .distantPast,
                defaultEnd: now.addingTimeInterval(1)
              ) else {
            buckets = []
            coverage = .gap
            refreshFailed = true
            return
        }
        do {
            let snapshot = try await controlPlane.decisionBuckets(
                from: range.start,
                to: range.end,
                width: query.time.decisionBucketWidth,
                anchor: window.start
            )
            buckets = snapshot.buckets
            coverage = snapshot.coverage
            refreshFailed = false
            if let hoveredBucket, !snapshot.buckets.contains(where: { $0.id == hoveredBucket.id }) {
                self.hoveredBucket = nil
            }
        } catch is CancellationError {
        } catch {
            refreshFailed = true
        }
    }

    private func updateHover(
        _ phase: HoverPhase,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        switch phase {
        case .active(let location):
            guard let plotFrame = proxy.plotFrame else {
                hoveredBucket = nil
                return
            }
            let frame = geometry[plotFrame]
            guard frame.contains(location),
                  let date: Date = proxy.value(atX: location.x - frame.minX) else {
                hoveredBucket = nil
                return
            }
            hoveredBucket = buckets.min {
                abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date))
            }
        case .ended:
            hoveredBucket = nil
        }
    }

    private func updateSelection(
        _ value: DragGesture.Value,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) {
        guard let start = chartDate(
            at: value.startLocation.x,
            proxy: proxy,
            geometry: geometry
        ), let end = chartDate(
            at: value.location.x,
            proxy: proxy,
            geometry: geometry
        ) else { return }
        query.selectTimeRange(min(start, end)...max(start, end), now: now, calendar: calendar)
        hoveredBucket = nil
    }

    private func chartDate(
        at x: CGFloat,
        proxy: ChartProxy,
        geometry: GeometryProxy
    ) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        let position = min(max(x - frame.minX, 0), frame.width)
        return proxy.value(atX: position)
    }

    private func hoverLabel(_ bucket: DecisionBucket) -> String {
        let time = bucket.start.formatted(date: .omitted, time: .shortened)
        return "\(time) · \(bucket.allowed)/\(bucket.denied)/\(bucket.unresolved)"
    }
}

import RiftControl
import SwiftUI

enum RiftTimelineMode: String, CaseIterable, Identifiable {
    case traffic = "Traffic"
    case decisions = "Decisions"
    var id: String { rawValue }
}

/// The slim timeline along the bottom of the Map page: traffic or decisions
/// over the selected time range, with one set of range controls.
struct RiftTimeline: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.openSettings) private var openSettings
    @Binding var mode: RiftTimelineMode
    @Binding var query: MonitorQueryState
    let traffic: LiveTrafficSnapshot
    let decisions: DecisionBucketSnapshot
    let now: Date
    let isMinimal: Bool
    let refreshFailed: Bool
    @State private var hoveredBucket: DecisionBucket?

    static let ranges: [MonitorTimeFilter] = [
        .twoMinutes, .tenMinutes, .hour, .fiveHours, .day,
        .threeDays, .week, .month, .thirtyDays, .all,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.s) {
            header
            Group {
                switch mode {
                case .traffic: TrafficBars(snapshot: traffic)
                case .decisions:
                    DecisionBars(
                        snapshot: decisions, query: $query, now: now,
                        selectable: !isMinimal, hovered: $hoveredBucket
                    )
                }
            }
            .frame(height: 44)
            timeAxis
        }
        .padding(.horizontal, RiftDesign.Spacing.l - 2)
        .padding(.vertical, RiftDesign.Spacing.m - 2)
        .accessibilityElement(children: .contain)
        .onChange(of: mode) { _, _ in hoveredBucket = nil }
    }

    /// Where the chart starts and ends, so a bar can be read against the clock.
    @ViewBuilder
    private var timeAxis: some View {
        if let window = query.baseTimeWindow(now: now, calendar: calendar), let start = window.start {
            let end = window.end ?? now
            let longRange = end.timeIntervalSince(start) > 86_400
            HStack {
                Text(start.formatted(date: longRange ? .abbreviated : .omitted, time: .shortened))
                Spacer()
                if mode == .decisions, !isMinimal {
                    Text("Drag to look at part of this range")
                    Spacer()
                }
                Text(query.isViewingPast
                    ? end.formatted(date: longRange ? .abbreviated : .omitted, time: .shortened)
                    : "Now")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
    }

    private var header: some View {
        HStack(spacing: RiftDesign.Spacing.m) {
            Picker("Show", selection: $mode) {
                ForEach(RiftTimelineMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            summary
            Spacer(minLength: RiftDesign.Spacing.s)
            if refreshFailed {
                Label("Couldn’t refresh", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .help("Rift couldn’t refresh. Showing what it loaded last.")
            }
            if isMinimal {
                Text("Recent connections · Not saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Rift keeps up to \(ControlPlaneController.minimalFlowLimit) recent connections for five minutes while this view is open.")
                Button("Keep History…") {
                    UserDefaults.standard.set(SettingsSection.history.rawValue, forKey: "settingsSection")
                    openSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
            } else {
                rangeControls
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var summary: some View {
        switch mode {
        case .traffic:
            HStack(spacing: RiftDesign.Spacing.m) {
                TrafficTotal(symbol: "arrow.up", title: "Sent", bytes: traffic.sent,
                             partial: traffic.partial, color: RiftDesign.trafficSent)
                TrafficTotal(symbol: "arrow.down", title: "Received", bytes: traffic.received,
                             partial: traffic.partial, color: RiftDesign.trafficReceived)
            }
        case .decisions:
            if let hoveredBucket {
                Text(hoverLabel(hoveredBucket))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                HStack(spacing: RiftDesign.Spacing.m) {
                    DecisionTotal(decision: .allowed, count: decisions.buckets.reduce(0) { $0 + $1.allowed })
                    DecisionTotal(decision: .denied, count: decisions.buckets.reduce(0) { $0 + $1.denied })
                    DecisionTotal(decision: .byDefault, count: decisions.buckets.reduce(0) { $0 + $1.unresolved })
                    if decisions.coverage != .complete {
                        Text("Partial").font(.caption).foregroundStyle(.tertiary)
                            .help("Some history is missing for this range.")
                    }
                }
            }
        }
    }

    private var rangeControls: some View {
        HStack(spacing: RiftDesign.Spacing.xs) {
            if query.selectedTimeRange != nil {
                Button {
                    query.selectTimeRange(nil, now: now, calendar: calendar)
                } label: {
                    Label("Clear Time Selection", systemImage: "xmark.circle.fill")
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Clear the selected time range")
            }
            Button { navigate(.previous) } label: {
                Label("Earlier", systemImage: "chevron.left")
            }
            .labelStyle(.iconOnly)
            .disabled(!query.canNavigateBackward)
            .help("Show the previous range")
            Picker("Time Range", selection: timeFilter) {
                ForEach(Self.ranges) { Text($0.rawValue).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityValue(displayedRangeLabel)
            .help(displayedRangeLabel)
            Button { navigate(.next) } label: {
                Label("Later", systemImage: "chevron.right")
            }
            .labelStyle(.iconOnly)
            .disabled(!query.canNavigateForward)
            .help("Show the next range")
            if query.isViewingPast {
                Text(displayedRangeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Back to Live") { query.showNow(); hoveredBucket = nil }
                    .help("Return to live activity")
            }
        }
    }

    private var timeFilter: Binding<MonitorTimeFilter> {
        Binding(get: { query.time }, set: { query.selectTimeFilter($0); hoveredBucket = nil })
    }

    private var displayedRangeLabel: String {
        if query.isLiveTimeRange { return query.time.liveLabel }
        guard let window = query.baseTimeWindow(now: now, calendar: calendar),
              let start = window.start, let end = window.end else { return query.time.rawValue }
        return start.formatted(date: .abbreviated, time: .shortened)
            + " – " + end.formatted(date: .abbreviated, time: .shortened)
    }

    private func navigate(_ direction: MonitorTimeNavigation) {
        query.navigateTime(direction, now: now, calendar: calendar)
        hoveredBucket = nil
    }

    private func hoverLabel(_ bucket: DecisionBucket) -> String {
        let time = bucket.start.formatted(date: .omitted, time: .shortened)
        return "\(time) · \(bucket.allowed) allowed · \(bucket.denied) blocked · \(bucket.unresolved) with no rule"
    }
}

private struct TrafficTotal: View {
    let symbol: String
    let title: String
    let bytes: UInt64
    let partial: Bool
    let color: Color

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.xs) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .fontWeight(.semibold)
                .accessibilityHidden(true)
            RiftBytesText(bytes: bytes, partial: partial)
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue((partial ? "At least " : "") + RiftFormat.bytes(bytes))
        .help(partial ? "\(title). Some connections didn’t report their size, so this is a lower bound." : title)
    }
}

private struct DecisionTotal: View {
    let decision: RiftDecision
    let count: Int

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.xs) {
            RiftDecisionBadge(decision: decision)
            Text(RiftFormat.count(count)).monospacedDigit()
        }
        .font(.callout)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) \(decision.label.lowercased())")
    }
}

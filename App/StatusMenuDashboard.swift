import RiftControl
import RiftCore
import SwiftUI

struct StatusMenuDashboard: View {
    let status: String
    let mode: String
    let profile: String
    let filteringConfirmed: Bool
    let pendingCount: Int
    let notificationsEnabled: Bool
    let rows: [MonitorEventRow]
    let recentLimit: Int
    let now: Date
    let artworkStore: ApplicationArtworkStore
    let toggleNotifications: () -> Void
    let openLiveMap: () -> Void
    let openActivity: (String) -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var traffic: StatusTrafficSnapshot {
        StatusTrafficSnapshot.make(rows: rows, now: now)
    }

    private var applications: [StatusApplicationActivity] {
        guard recentLimit > 0 else { return [] }
        var seen = Set<String>()
        var result: [StatusApplicationActivity] = []
        for row in rows {
            let identity = row.event.flow.sourceAppIdentity
                ?? row.event.flow.sourceProcessIdentity
            let key = identity.map { String(reflecting: $0) }
                ?? MonitorQuery.applicationLabel(row)
            guard seen.insert(key).inserted else { continue }
            result.append(StatusApplicationActivity(
                id: key,
                eventID: row.id,
                identity: identity,
                name: MonitorQuery.applicationLabel(row),
                destination: MonitorQuery.endpointLabel(row),
                denied: row.event.reason == .concreteDecision && row.event.action == .deny,
                occurredAt: row.event.occurredAt
            ))
            if result.count >= recentLimit { break }
        }
        return result
    }

    private var recentDenied: [MonitorEventRow] {
        let cutoff = now.addingTimeInterval(-300)
        return rows.filter {
            $0.event.occurredAt >= cutoff
                && $0.event.reason == .concreteDecision
                && $0.event.action == .deny
        }
    }

    private var surfaceFill: Color {
        colorScheme == .dark ? .white.opacity(0.075) : .black.opacity(0.045)
    }

    private var surfaceStroke: Color {
        colorScheme == .dark ? .white.opacity(0.14) : .black.opacity(0.12)
    }

    private var operationSurfaceFill: Color {
        Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.11)
    }

    private var operationColor: Color {
        if pendingCount > 0 || !filteringConfirmed { return .orange }
        if mode == "Observe Only" { return .blue }
        return .green
    }

    private var operationSymbol: String {
        if pendingCount > 0 { return "exclamationmark" }
        if !filteringConfirmed { return "exclamationmark.triangle.fill" }
        if mode == "Observe Only" { return "eye.fill" }
        return "checkmark"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            controlStrip
            trafficCard
            recentSection
            Divider()
            deniedSection
        }
    }

    private var controlStrip: some View {
        HStack(spacing: 6) {
            HStack(spacing: 8) {
                ZStack {
                    Circle().fill(operationColor)
                    Image(systemName: operationSymbol)
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 27, height: 27)

                VStack(alignment: .leading, spacing: -1) {
                    Text("Mode")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(mode)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 38)
            .background(operationSurfaceFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(surfaceStroke, lineWidth: 0.75)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Mode: \(mode)")
            .accessibilityValue("\(status). Profile: \(profile)")

            StatusQuickActionButton(
                symbol: notificationsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                label: notificationsEnabled
                    ? "Turn off connection notifications"
                    : "Turn on connection notifications",
                action: toggleNotifications
            )
            StatusQuickActionButton(
                symbol: "globe.americas.fill",
                label: "Open Live Map",
                action: openLiveMap
            )
        }
    }

    private var trafficCard: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(surfaceFill)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(surfaceStroke, lineWidth: 0.75)

            StatusTrafficBars(snapshot: traffic)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)

            VStack(alignment: .leading, spacing: 0) {
                StatusTrafficValueBadge(
                    value: traffic.prefix + byteLabel(traffic.sent),
                    color: RiftDesign.trafficSent
                )
                Spacer()
                StatusTrafficValueBadge(
                    value: traffic.prefix + byteLabel(traffic.received),
                    color: RiftDesign.trafficReceived
                )
                HStack {
                    Text("5 minutes ago")
                    Spacer()
                    Text("now")
                }
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.top, 3)
            }
            .padding(8)
        }
        .frame(height: 146)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Network traffic during the last 5 minutes")
        .accessibilityValue(
            "Sent \(traffic.prefix)\(byteLabel(traffic.sent)); received \(traffic.prefix)\(byteLabel(traffic.received))"
        )
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Recent Network Activity")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            if applications.isEmpty {
                Text("No recent activity")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            } else {
                ForEach(applications) { item in
                    Button { openActivity(item.eventID) } label: {
                        HStack(spacing: 7) {
                            ApplicationIdentityIcon(
                                identity: item.identity,
                                fallbackSystemName: "app.dashed",
                                size: 17,
                                artworkStore: artworkStore
                            )
                            Text(item.name)
                                .font(.system(size: 12.5, weight: .regular))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(item.destination)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .frame(maxWidth: 104, alignment: .trailing)
                            Image(systemName: item.denied ? "xmark.circle.fill" : "circle.fill")
                                .font(.system(size: item.denied ? 10 : 6, weight: .semibold))
                                .foregroundStyle(item.denied ? .red : .green)
                                .accessibilityLabel(item.denied ? "Denied" : "Allowed")
                        }
                        .frame(maxWidth: .infinity, minHeight: 22)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(relativeTime(item.occurredAt))
                }
            }
        }
    }

    private var deniedSection: some View {
        Button {
            if let eventID = recentDenied.first?.id { openActivity(eventID) }
        } label: {
            HStack(spacing: 6) {
                Text("Recently Denied")
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                if !recentDenied.isEmpty {
                    Text(String(recentDenied.count))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.red)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(recentDenied.isEmpty)
        .accessibilityValue("\(recentDenied.count) in the last 5 minutes")
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 10 { return "Just now" }
        if seconds < 60 { return ago(Int(seconds), "second") }
        if seconds < 3_600 { return ago(Int(seconds / 60), "minute") }
        if seconds < 86_400 { return ago(Int(seconds / 3_600), "hour") }
        return ago(Int(seconds / 86_400), "day")
    }

    private func ago(_ value: Int, _ unit: String) -> String {
        value == 1 ? "1 \(unit) ago" : "\(value) \(unit)s ago"
    }
}

private struct StatusQuickActionButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 37, height: 37)
                .background(Color.accentColor.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(.white.opacity(0.18), lineWidth: 0.75)
                }
        }
        .buttonStyle(RiftPressButtonStyle())
        .accessibilityLabel(label)
        .help(label)
    }
}

private struct StatusTrafficValueBadge: View {
    let value: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(value)
                .font(.system(size: 10.5, weight: .medium).monospacedDigit())
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(.regularMaterial, in: Capsule())
    }
}

private struct StatusTrafficBars: View {
    let snapshot: StatusTrafficSnapshot

    var body: some View {
        Canvas { context, size in
            let count = max(snapshot.bins.count, 1)
            let slot = size.width / CGFloat(count)
            let barWidth = max(1, slot - 1.1)
            let topInset: CGFloat = 17
            let bottomInset: CGFloat = 31
            let baseline = topInset + (size.height - topInset - bottomInset) * 0.52
            let sentRange = max(1, baseline - topInset)
            let receivedRange = max(1, size.height - bottomInset - baseline)
            let maximum = max(snapshot.maximum, 1)

            context.fill(
                Path(CGRect(x: 0, y: baseline, width: size.width, height: 0.75)),
                with: .color(.secondary.opacity(0.26))
            )

            for index in snapshot.bins.indices {
                let x = CGFloat(index) * slot + (slot - barWidth) / 2
                context.fill(
                    Path(CGRect(
                        x: x,
                        y: topInset,
                        width: barWidth,
                        height: size.height - topInset - bottomInset
                    )),
                    with: .color(.primary.opacity(0.07))
                )

                let bin = snapshot.bins[index]
                let sentHeight = CGFloat(bin.sent) / CGFloat(maximum) * sentRange
                let receivedHeight = CGFloat(bin.received) / CGFloat(maximum) * receivedRange
                if sentHeight > 0 {
                    context.fill(
                        Path(CGRect(
                            x: x,
                            y: baseline - max(1, sentHeight),
                            width: barWidth,
                            height: max(1, sentHeight)
                        )),
                        with: .color(RiftDesign.trafficSent)
                    )
                }
                if receivedHeight > 0 {
                    context.fill(
                        Path(CGRect(
                            x: x,
                            y: baseline,
                            width: barWidth,
                            height: max(1, receivedHeight)
                        )),
                        with: .color(RiftDesign.trafficReceived)
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }
}

private struct StatusApplicationActivity: Identifiable {
    let id: String
    let eventID: String
    let identity: ProcessIdentity?
    let name: String
    let destination: String
    let denied: Bool
    let occurredAt: Date
}

private struct StatusTrafficBin {
    var sent: UInt64 = 0
    var received: UInt64 = 0
}

private struct StatusTrafficSnapshot {
    let bins: [StatusTrafficBin]
    let sent: UInt64
    let received: UInt64
    let partial: Bool

    var prefix: String { partial ? "≥" : "" }
    var maximum: UInt64 {
        bins.reduce(0) { max($0, max($1.sent, $1.received)) }
    }

    static func make(rows: [MonitorEventRow], now: Date) -> StatusTrafficSnapshot {
        let count = 60
        let duration: TimeInterval = 300
        let start = now.addingTimeInterval(-duration)
        var bins = Array(repeating: StatusTrafficBin(), count: count)
        var sent: UInt64 = 0
        var received: UInt64 = 0
        var partial = false
        for row in rows where row.event.occurredAt >= start && row.event.occurredAt <= now {
            let progress = row.event.occurredAt.timeIntervalSince(start) / duration
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
        return StatusTrafficSnapshot(
            bins: bins, sent: sent, received: received, partial: partial
        )
    }

    private static func adding(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : sum
    }
}

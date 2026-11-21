import AppKit
import RiftCore
import SwiftUI

/// A temporary rule that's still running.
struct StatusTemporaryRule: Identifiable, Equatable {
    let id: UUID
    let action: RuleAction
    let summary: String
    let expiresAt: Date
}

/// The latest blocked connections, each with a quick way to let it through
/// for a while.
struct StatusMenuBlockedList: View {
    let items: [StatusApplicationActivity]
    let now: Date
    let artworkStore: ApplicationArtworkStore
    let open: (String) -> Void
    let allowForFiveMinutes: (String) -> Void

    var body: some View {
        if !items.isEmpty {
            StatusMenuSection(title: "Recently Blocked") {
                ForEach(items, id: \.eventID) { item in
                    HStack(spacing: RiftDesign.Spacing.xs) {
                        StatusMenuButton(action: { open(item.eventID) }) {
                            HStack(spacing: RiftDesign.Spacing.s) {
                                ApplicationIdentityIcon(
                                    identity: item.identity, fallbackSystemName: "app.dashed",
                                    size: 16, artworkStore: artworkStore
                                )
                                VStack(alignment: .leading, spacing: 0) {
                                    ApplicationNameText(identity: item.identity, fallback: item.name, artworkStore: artworkStore)
                                        .lineLimit(1)
                                    Text(item.destination)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer(minLength: RiftDesign.Spacing.xs)
                                Text(RiftRelativeTime.short(item.occurredAt, now: now))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .accessibilityHint("Shows this connection in Rift")
                        Button { allowForFiveMinutes(item.eventID) } label: {
                            Label("Allow for 5 Minutes", systemImage: "clock.badge.checkmark")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Allow this app to reach this destination for 5 minutes")
                    }
                    .contextMenu {
                        Button("Allow for 5 Minutes") { allowForFiveMinutes(item.eventID) }
                        Button("Show in Rift") { open(item.eventID) }
                        Divider()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("\(item.name) → \(item.destination)", forType: .string)
                        }
                    }
                }
            }
        }
    }
}

/// Temporary rules that are still running, with the time left.
struct StatusMenuTemporaryRules: View {
    let rules: [StatusTemporaryRule]
    let now: Date
    let makePermanent: (UUID) -> Void
    let remove: (UUID) -> Void

    var body: some View {
        let running = rules.filter { $0.expiresAt > now }
        if !running.isEmpty {
            StatusMenuSection(title: "Temporary Rules") {
                ForEach(running) { rule in
                    HStack(spacing: RiftDesign.Spacing.s) {
                        Image(systemName: symbol(rule.action))
                            .foregroundStyle(rule.action == .filter(.deny) ? RiftDecision.denied.color : .secondary)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(rule.summary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: RiftDesign.Spacing.xs)
                        Text(remaining(rule.expiresAt))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Button { remove(rule.id) } label: {
                            Label("Remove Rule", systemImage: "xmark.circle")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove this rule now")
                    }
                    .padding(.horizontal, RiftDesign.Spacing.xs + 2)
                    .padding(.vertical, RiftDesign.Spacing.xxs)
                    .accessibilityElement(children: .combine)
                    .accessibilityAction(named: "Make Permanent") { makePermanent(rule.id) }
                    .accessibilityAction(named: "Remove Rule") { remove(rule.id) }
                    .contextMenu {
                        Button("Make Permanent") { makePermanent(rule.id) }
                        Button("Remove Rule", role: .destructive) { remove(rule.id) }
                    }
                }
            }
        }
    }

    private func symbol(_ action: RuleAction) -> String {
        switch action {
        case .filter(.allow): RiftDecision.allowed.symbol
        case .filter(.deny): RiftDecision.denied.symbol
        default: "questionmark"
        }
    }

    private func remaining(_ end: Date) -> String {
        let seconds = max(0, end.timeIntervalSince(now))
        if seconds < 60 { return "\(Int(seconds))s left" }
        if seconds < 3_600 { return "\(Int((seconds / 60).rounded(.up)))m left" }
        return "\(Int(seconds / 3_600))h left"
    }
}

struct StatusMenuSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, RiftDesign.Spacing.xs + 2)
                .padding(.bottom, RiftDesign.Spacing.xs)
            content
        }
    }
}

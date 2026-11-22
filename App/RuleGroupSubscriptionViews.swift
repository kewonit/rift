import RiftControl
import SwiftUI

/// Subscribes to a `.lsrules` file at a web address: Rift reads the file
/// first and says what it would add, then the person confirms.
struct RuleGroupSubscribeSheet: View {
    /// What happened, and the new group, once subscribed.
    let finished: @MainActor (String, UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var interval: BlocklistUpdateInterval = .daily
    @State private var holdsNewAllowRules = true
    @State private var pending: PendingRuleGroupSubscription?
    @State private var working = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: RiftDesign.Spacing.m) {
            Text("Subscribe to a Rule Group").font(.title3.weight(.semibold))
            Text("Enter the address of a .lsrules file. Rift adds its rules as a group and keeps them up to date.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Address", text: $address, prompt: Text("https://example.com/rules.lsrules"))
                .textContentType(.URL)
                .disabled(pending != nil || working)
                .onSubmit(check)
            Picker("Check for updates", selection: $interval) {
                ForEach(BlocklistUpdateInterval.allCases) { Text($0.title).tag($0) }
            }
            .fixedSize()
            Toggle("Keep new allow rules off until I turn them on", isOn: $holdsNewAllowRules)
            Text("When an update adds a rule that allows connections, it stays off until you turn it on. High-priority rules always wait.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let pending {
                Label(pending.summary, systemImage: "doc.text")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if let message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Text("Rift downloads the file now and checks for a new version while it’s running. The file’s server sees your IP address, as with any download. Each update replaces the group’s rules from the file, so edits you make to them don’t last.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                if working { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                if pending == nil {
                    Button("Check File", action: check)
                        .keyboardShortcut(.defaultAction)
                        .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                } else {
                    Button("Subscribe", action: subscribe).keyboardShortcut(.defaultAction).disabled(working)
                }
            }
        }
        .padding(RiftDesign.Spacing.xl)
        .frame(width: 480)
    }

    private func check() {
        guard !working, pending == nil else { return }
        working = true
        message = nil
        Task { @MainActor in
            defer { working = false }
            do {
                pending = try await RuleGroupSubscriptions.shared.preview(address: address)
            } catch {
                message = String(localized: "Couldn’t read the file. \(RuleGroupSubscriptions.message(for: error))")
            }
        }
    }

    private func subscribe() {
        guard let pending, !working else { return }
        working = true
        Task { @MainActor in
            defer { working = false }
            do {
                let (result, groupID) = try await RuleGroupSubscriptions.shared.subscribe(
                    pending, interval: interval, holdsNewAllowRules: holdsNewAllowRules
                )
                let added = String(localized: "Subscribed. \(pending.ruleCount) rules added.")
                finished(result.requiresAttention ? "\(added) \(result.message)" : added, groupID)
                dismiss()
            } catch {
                message = String(localized: "Couldn’t subscribe. \(RuleGroupSubscriptions.message(for: error))")
            }
        }
    }
}

/// Where a subscribed group comes from, when it was checked, and rules an
/// update is holding for approval.
struct RuleGroupSubscriptionBanner: View {
    let groupID: UUID
    /// Changes whenever the rules do, so approvals made in Rules are noticed.
    let generation: UInt64
    let reload: @MainActor () async -> Void
    let select: @MainActor (Set<UUID>) -> Void
    @State private var message: String?
    private var subscriptions: RuleGroupSubscriptions { .shared }

    var body: some View {
        if let item = subscriptions.items[groupID] {
            VStack(alignment: .leading, spacing: RiftDesign.Spacing.s) {
                HStack(spacing: RiftDesign.Spacing.s) {
                    if let failure = item.lastFailure {
                        Label(failure, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    } else {
                        Label(detail(item), systemImage: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: RiftDesign.Spacing.s)
                    Toggle("Hold new allow rules", isOn: Binding(
                        get: { item.holdsNewAllowRules },
                        set: { subscriptions.setHoldsNewAllowRules($0, for: groupID) }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(ConfigurationLock.shared.isLocked)
                    .help("Keep allow rules that arrive in an update off until you turn them on")
                    Picker("Check", selection: Binding(
                        get: { item.effectiveInterval },
                        set: { subscriptions.setInterval($0, for: groupID) }
                    )) {
                        ForEach(BlocklistUpdateInterval.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .disabled(ConfigurationLock.shared.isLocked)
                    .help("How often Rift checks this file while it’s running")
                    if subscriptions.refreshing.contains(groupID) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Update Now") { run { await subscriptions.refresh(groupID) } }
                    }
                }
                if !item.pendingRuleIDs.isEmpty {
                    HStack(spacing: RiftDesign.Spacing.s) {
                        let count = item.pendingRuleIDs.count
                        Label(count == 1
                            ? "1 new allow rule from an update is off until you turn it on."
                            : "\(count) new allow rules from an update are off until you turn them on.",
                            systemImage: "hand.raised")
                        Spacer(minLength: RiftDesign.Spacing.s)
                        Button("Show") { select(Set(item.pendingRuleIDs)) }
                        Button(count == 1 ? "Turn On" : "Turn On All") {
                            run { await subscriptions.approvePending(groupID) }
                        }
                        .disabled(ConfigurationLock.shared.isLocked)
                    }
                }
                if let message {
                    Text(message).foregroundStyle(.secondary)
                }
            }
            .font(.caption)
            .controlSize(.small)
            .lineLimit(2)
            .padding(8)
            .background(Color.accentColor.opacity(0.08))
            .task(id: generation) { await subscriptions.notePendingChanges() }
        }
    }

    private func run(_ action: @escaping @MainActor () async -> String) {
        Task { @MainActor in
            message = await action()
            await reload()
        }
    }

    private func detail(_ item: RuleGroupSubscription) -> String {
        let host = BlocklistSubscriptionAddress.host(of: item.url)
        let updates = item.effectiveInterval.phrase
        guard let checked = item.lastCheckedAt else { return String(localized: "Subscribed • \(updates) from \(host)") }
        return String(localized: "Subscribed • \(updates) from \(host) • Checked \(checked.formatted(.relative(presentation: .named)))")
    }
}

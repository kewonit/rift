import RiftControl
import RiftCore
import SwiftUI

/// Apps that connected with no rule, and alerts nobody answered, each with
/// one-click Allow and Block.
struct ReviewView: View {
    @Bindable var model: ReviewQueueModel
    let mode: OperationMode
    let keepsHistory: Bool
    let artworkStore: ApplicationArtworkStore
    let showOnMap: (ReviewQueue.App) -> Void
    let switchToAskMe: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: RiftDesign.Spacing.xs) {
                Text("Review").font(.title2.weight(.semibold))
                Text(keepsHistory
                    ? "Connections from the last 7 days that no rule decides yet."
                    : "Recent connections that no rule decides yet. Turn on history in Settings › History to review the last 7 days.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(RiftDesign.Spacing.l)
            Divider()
            content
            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(RiftDesign.Spacing.m)
        }
        .frame(width: 560, height: 540)
        .task { await model.refresh() }
    }

    @ViewBuilder
    private var content: some View {
        if !model.loaded {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.queue.isEmpty {
            VStack(spacing: RiftDesign.Spacing.s) {
                Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Nothing to review").font(.headline)
                Text("Every app that connected has a rule.")
                    .foregroundStyle(.secondary)
                if mode == .silentAllow {
                    Text("To be asked about new connections from now on, switch to Ask Me.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Switch to Ask Me", action: switchToAskMe)
                }
            }
            .padding(RiftDesign.Spacing.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                if !model.queue.apps.isEmpty {
                    Section("Apps with no rule") {
                        ForEach(model.queue.apps) { app in
                            ReviewAppRow(
                                app: app, artworkStore: artworkStore,
                                busy: model.applying.contains(app.id),
                                decide: { action, name in model.decide(action, app: app, name: name) },
                                showOnMap: { showOnMap(app) },
                                notNow: { model.dismiss(app) }
                            )
                        }
                    }
                }
                if !model.queue.unanswered.isEmpty {
                    Section("Alerts nobody answered") {
                        ForEach(model.queue.unanswered) { item in
                            ReviewUnansweredRow(
                                item: item, artworkStore: artworkStore,
                                busy: model.applying.contains(item.id),
                                decide: { action, name in model.decide(action, unanswered: item, name: name) }
                            )
                        }
                    }
                }
            }
            .listStyle(.inset)
        }
    }
}

private struct ReviewAppRow: View {
    let app: ReviewQueue.App
    let artworkStore: ApplicationArtworkStore
    let busy: Bool
    let decide: (FilterAction, String) -> Void
    let showOnMap: () -> Void
    let notNow: () -> Void
    @State private var name: String?

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.m) {
            ApplicationIdentityIcon(identity: app.identity, fallbackSystemName: "app.dashed", size: 28, artworkStore: artworkStore)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).lineLimit(1)
                Text(summary)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: RiftDesign.Spacing.s)
            ReviewDecisionButtons(busy: busy, decide: { decide($0, displayName) })
            Menu {
                Button("Show on Map", action: showOnMap)
                Button("Not Now", action: notNow)
                    .help("Hides this app until it connects somewhere new.")
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("More for \(displayName)")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .task(id: app.identity) {
            name = await artworkStore.artwork(for: app.identity)?.displayName
        }
    }

    private var displayName: String {
        DisplaySanitizer.plainText(name ?? MonitorQuery.identityLabel(app.identity))
    }

    private var summary: String {
        let hosts = app.destinations.prefix(3).map { DisplaySanitizer.plainText($0.host) }
        let more = app.destinations.count - hosts.count
        let list = hosts.joined(separator: ", ") + (more > 0 ? " and \(more) more" : "")
        let last = app.lastSeen.formatted(.relative(presentation: .named))
        return "\(list) · last seen \(last)"
    }
}

private struct ReviewUnansweredRow: View {
    let item: ReviewQueue.Unanswered
    let artworkStore: ApplicationArtworkStore
    let busy: Bool
    let decide: (FilterAction, String) -> Void
    @State private var name: String?

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.m) {
            ApplicationIdentityIcon(identity: item.identity, fallbackSystemName: "app.dashed", size: 28, artworkStore: artworkStore)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).lineLimit(1)
                Text("\(DisplaySanitizer.plainText(item.host)) · \(outcome) · \(item.lastSeen.formatted(.relative(presentation: .named)))")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: RiftDesign.Spacing.s)
            ReviewDecisionButtons(busy: busy, decide: { decide($0, displayName) })
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .contain)
        .task(id: item.identity) {
            name = await artworkStore.artwork(for: item.identity)?.displayName
        }
    }

    private var displayName: String {
        DisplaySanitizer.plainText(name ?? MonitorQuery.identityLabel(item.identity))
    }

    private var outcome: String {
        let verb = item.row.event.action == .deny ? "blocked" : "allowed"
        return item.count == 1 ? "\(verb) when nobody answered" : "\(verb) \(item.count) times when nobody answered"
    }
}

private struct ReviewDecisionButtons: View {
    let busy: Bool
    let decide: (FilterAction) -> Void

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.xs) {
            Button("Block") { decide(.deny) }
            Button("Allow") { decide(.allow) }
        }
        .controlSize(.small)
        .disabled(busy)
    }
}

import RiftControl
import SwiftUI

/// Where a subscribed blocklist comes from and when it was last checked,
/// with a way to check now.
struct BlocklistSubscriptionStatus: View {
    let sourceID: UUID
    let reload: @MainActor () async -> Void
    @Binding var message: String?
    private var subscriptions: BlocklistSubscriptions { .shared }

    var body: some View {
        if let item = subscriptions.items[sourceID] {
            HStack(spacing: RiftDesign.Spacing.s) {
                if let failure = item.lastFailure {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Text(detail(item)).foregroundStyle(.secondary)
                }
                Spacer(minLength: RiftDesign.Spacing.s)
                if subscriptions.refreshing.contains(sourceID) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Update Now") {
                        Task { @MainActor in
                            message = await subscriptions.refresh(sourceID)
                            await reload()
                        }
                    }
                    .controlSize(.small)
                }
            }
            .font(.caption)
            .lineLimit(2)
        }
    }

    private func detail(_ item: BlocklistSubscription) -> String {
        let host = BlocklistSubscriptionAddress.host(of: item.url)
        guard let checked = item.lastCheckedAt else { return "Updates daily from \(host)" }
        let when = checked.formatted(.relative(presentation: .named))
        return "Updates daily from \(host) • Checked \(when)"
    }
}

/// Subscribes to a list at a web address the person enters.
struct BlocklistSubscribeRow: View {
    @Binding var name: String
    @Binding var message: String?
    let reload: @MainActor () async -> Void
    @State private var address = ""
    @State private var subscribing = false

    var body: some View {
        HStack {
            TextField("Or subscribe to a web address", text: $address, prompt: Text("https://example.com/list.txt"))
                .textContentType(.URL)
                .onSubmit(subscribe)
            if subscribing {
                ProgressView().controlSize(.small)
            } else {
                Button("Subscribe", action: subscribe)
                    .disabled(!canSubscribe)
            }
        }
        Text("Rift downloads a subscribed list now and checks for a new version once a day while it’s running. The list’s server sees your IP address, as with any download.")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var canSubscribe: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func subscribe() {
        guard canSubscribe, !subscribing else { return }
        subscribing = true
        Task { @MainActor in
            defer { subscribing = false }
            do {
                let result = try await BlocklistSubscriptions.shared.subscribe(address: address, name: name)
                message = result.message
                address = ""
                name = ""
            } catch {
                message = "Couldn’t subscribe. " + BlocklistSubscriptions.message(for: error)
            }
            await reload()
        }
    }
}

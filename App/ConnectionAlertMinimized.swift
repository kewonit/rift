import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

/// A small bar in place of the alert: who's connecting, where, and how long
/// until the connection is allowed, because a minimized alert still waits.
struct ConnectionAlertMinimizedView: View {
    let prompt: PromptRequest
    let others: [PromptRequest]
    let controller: ControlPlaneController
    let artworkStore: ApplicationArtworkStore
    let expand: () -> Void
    let choose: (UUID) -> Void
    @AppStorage(PromptPanelController.keepMinimizedKey) private var keepMinimized = false
    @State private var applicationName: String?

    var body: some View {
        HStack(spacing: RiftDesign.Spacing.s) {
            ApplicationIdentityIcon(
                identity: identity, fallbackSystemName: "app.dashed", size: 22, artworkStore: artworkStore
            )
            VStack(alignment: .leading, spacing: 1) {
                Text(DisplaySanitizer.plainText(applicationName ?? MonitorQuery.identityLabel(identity)))
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(DisplaySanitizer.plainText(ConnectionAlertFacts(prompt: prompt).destination))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(ConnectionAlertCountdown.label(for: prompt, now: context.date))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .accessibilityLabel(ConnectionAlertSpeech.countdown(for: prompt, now: context.date))
                }
            }
            Spacer(minLength: RiftDesign.Spacing.s)
            ConnectionAlertWaitingMenu(others: others, compact: true, choose: choose)
            Button("Show", action: expand)
                .keyboardShortcut(.defaultAction)
                .help("Show the whole alert to decide")
            Menu {
                Toggle("Keep Alerts Minimized", isOn: $keepMinimized)
            } label: {
                Label("Alert Options", systemImage: "ellipsis.circle").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Alert options")
        }
        .padding(.horizontal, RiftDesign.Spacing.m)
        .padding(.vertical, RiftDesign.Spacing.s)
        .frame(width: 380)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Connection waiting for a decision")
        // The bar can appear without the whole alert ever showing, so it
        // says what's waiting, and when ten seconds are left.
        .modifier(ConnectionAlertAnnouncements(prompt: prompt, arrivalHeadline: arrivalHeadline))
        .task(id: prompt.nonce) {
            // As in the full alert: if news that the filter resolved the
            // connection never arrives, clear it after the deadline.
            let wait = prompt.deadline.timeIntervalSinceNow + 2
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            controller.removePendingPrompt(prompt.nonce)
        }
        .task(id: identity) {
            applicationName = nil
            guard let identity else { return }
            let name = await artworkStore.artwork(for: identity)?.displayName
            if !Task.isCancelled { applicationName = name }
        }
    }

    private var identity: ProcessIdentity? { prompt.appIdentity ?? prompt.processIdentity }

    private var arrivalHeadline: String {
        ConnectionAlertPresentation.headline(
            application: DisplaySanitizer.plainText(applicationName ?? MonitorQuery.identityLabel(identity)),
            destination: DisplaySanitizer.plainText(ConnectionAlertFacts(prompt: prompt).destination),
            direction: prompt.direction
        )
    }
}

/// "+N waiting", as a menu to answer another waiting connection first.
struct ConnectionAlertWaitingMenu: View {
    let others: [PromptRequest]
    var compact = false
    let choose: (UUID) -> Void

    var body: some View {
        if !others.isEmpty {
            Menu {
                Section("Answer Another") {
                    ForEach(others, id: \.nonce) { prompt in
                        Button(label(for: prompt)) { choose(prompt.nonce) }
                    }
                }
            } label: {
                Text(compact ? "+\(others.count)" : ConnectionAlertPresentation.moreWaitingLabel(others.count) ?? "")
                    .monospacedDigit()
            }
            .accessibilityLabel(others.count == 1 ? "1 more connection waiting" : "\(others.count) more connections waiting")
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            .help(others.count == 1 ? "1 more connection is waiting" : "\(others.count) more connections are waiting")
        }
    }

    private func label(for prompt: PromptRequest) -> String {
        let app = MonitorQuery.identityLabel(prompt.appIdentity ?? prompt.processIdentity)
        let destination = ConnectionAlertFacts(prompt: prompt).destination
        return DisplaySanitizer.plainText("\(app) → \(destination)")
    }
}

enum ConnectionAlertCountdown {
    /// Settings › Alerts can block unanswered connections instead of allowing
    /// them. A filter that speaks protocol 1.4 does it itself. For an older
    /// one, Rift answers Block just before the filter's deadline.
    static let blocksUnansweredKey = UnansweredAlertSettings.blocksKey

    static var blocksUnanswered: Bool { UserDefaults.standard.bool(forKey: blocksUnansweredKey) }

    /// What happens to this connection if nobody answers.
    static func outcome(for prompt: PromptRequest) -> UnansweredAlertOutcome {
        UnansweredAlertOutcome(prompt: prompt, blocksUnanswered: blocksUnanswered)
    }

    static func label(for prompt: PromptRequest, now: Date) -> String {
        outcome(for: prompt).countdownLabel(for: prompt, now: now)
    }
}

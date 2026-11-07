#if DEBUG
import AppKit
import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

/// Debug-only launch options for reviewing surfaces that are hard to reach
/// in a preview: a starting page, the Settings window, and a connection alert.
enum FixturePreviewOptions {
    static var initialPage: AppDestination? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-fixture-page"),
              arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1].lowercased() {
        case "rules": return .rules
        case "status", "health": return .health
        case "map": return .liveMap
        default: return nil
        }
    }

    static var opensSettings: Bool { ProcessInfo.processInfo.arguments.contains("--ui-fixture-settings") }
    static var showsAlert: Bool { ProcessInfo.processInfo.arguments.contains("--ui-fixture-alert") }

    /// Blocks the first connection through the real action path, and undoes it
    /// a few seconds later with `undo`.
    static var sampleRuleAction: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-fixture-apply-rule"),
              arguments.indices.contains(flag + 1) else { return nil }
        return arguments[flag + 1]
    }

    /// Starts the Map narrowed to one country, as if its marker was clicked.
    static var sampleCountry: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-fixture-country"),
              arguments.indices.contains(flag + 1) else { return nil }
        return arguments[flag + 1]
    }

    /// How many alerts to show in the real panel, with a real 30 second deadline.
    static var panelPromptCount: Int? {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-fixture-alert-queue") { return 3 }
        return arguments.contains("--ui-fixture-alert-panel") ? 1 : nil
    }

    static var showsSetupQuestion: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-fixture-status"),
              arguments.indices.contains(flag + 1) else { return false }
        return arguments[flag + 1] == "setup-question"
    }

    /// Shows one status instead of Preview, for reviewing how each state reads.
    static var statusInputs: ProtectionInputs? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--ui-fixture-status"),
              arguments.indices.contains(flag + 1) else { return nil }
        var healthy = ProtectionInputs(
            lifecycle: .enabled, controller: .connected(.ready), filterServiceConfirmed: true,
            hasActivePolicy: true, desiredKnown: true, rulesMatchDesired: true, mode: .silentAllow
        )
        switch arguments[flag + 1].lowercased() {
        case "cannot-filter": return ProtectionInputs(buildCanFilter: false)
        case "unreadable":
            return ProtectionInputs(lifecycle: .enabled, hasActivePolicy: true, configurationUnreadable: true)
        case "setup": return ProtectionInputs(lifecycle: .notInstalled)
        case "installing":
            return ProtectionInputs(lifecycle: .activating, lifecycleTitle: "Installing the network filter…")
        case "approval": return ProtectionInputs(lifecycle: .awaitingApproval)
        case "off": return ProtectionInputs(lifecycle: .disabled)
        case "problem":
            return ProtectionInputs(lifecycle: .failed(message: "macOS couldn’t turn on the filter."))
        case "connecting": return ProtectionInputs(lifecycle: .enabled)
        case "unreachable": return ProtectionInputs(lifecycle: .enabled, controller: .unreachable)
        case "allowing":
            return ProtectionInputs(lifecycle: .enabled, controller: .connected(.degradedNoPolicy))
        case "at-risk":
            healthy.controller = .connected(.degradedPersistence)
        case "not-current":
            healthy.rulesMatchDesired = false
        case "waiting": healthy.waitingPrompts = 2
        case "ask": healthy.mode = .alert
        case "block": healthy.mode = .silentDeny
        case "paused": healthy.mode = .filterOff
        case "watch", "setup-question": break
        default: return nil
        }
        return healthy
    }

}

/// Shows the connection alert in an ordinary window with a sample request.
struct AlertFixtureHost: View {
    @Bindable var session: AppSession

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let prompt = Self.samplePrompts(count: 1, deadline: Date().addingTimeInterval(3_600)).first {
                ConnectionAlertView(
                    prompt: prompt,
                    controller: session.controlPlane,
                    artworkStore: session.applicationArtwork
                )
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: RiftDesign.Radius.panel, style: .continuous))
                .shadow(color: .black.opacity(0.22), radius: 18, y: 8)
            }
        }
        .frame(minWidth: 640, minHeight: 560)
    }

    static func samplePrompts(count: Int, deadline: Date) -> [PromptRequest] {
        MonitorFixtureData.rows
            .filter { $0.event.flow.remoteEndpoint != nil }
            .prefix(count)
            .map { row in
                let flow = row.event.flow
                return PromptRequest(
                    nonce: UUID(), providerEpoch: row.event.providerEpoch,
                    lineageID: UUID(), generation: 1, flowID: flow.flowID,
                    observedAt: Date(), deadline: deadline,
                    owner: flow.owner, appIdentity: flow.sourceAppIdentity,
                    processIdentity: flow.sourceProcessIdentity, direction: .outgoing,
                    transportProtocol: flow.transportProtocol, endpoint: flow.remoteEndpoint,
                    winningRuleID: nil, affectingRuleIDs: []
                )
            }
    }
}
#endif

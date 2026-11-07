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

}

/// Shows the connection alert in an ordinary window with a sample request.
struct AlertFixtureHost: View {
    @Bindable var session: AppSession

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if let prompt = Self.samplePrompt {
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

    private static var samplePrompt: PromptRequest? {
        guard let row = MonitorFixtureData.rows.first(where: { $0.event.flow.remoteEndpoint != nil }) else {
            return nil
        }
        let flow = row.event.flow
        return PromptRequest(
            nonce: UUID(), providerEpoch: row.event.providerEpoch,
            lineageID: UUID(), generation: 1, flowID: flow.flowID,
            observedAt: Date(), deadline: Date().addingTimeInterval(3_600),
            owner: flow.owner, appIdentity: flow.sourceAppIdentity,
            processIdentity: flow.sourceProcessIdentity, direction: .outgoing,
            transportProtocol: flow.transportProtocol, endpoint: flow.remoteEndpoint,
            winningRuleID: nil, affectingRuleIDs: []
        )
    }
}
#endif

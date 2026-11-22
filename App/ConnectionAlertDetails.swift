import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

/// Plain facts about one alert, shared by its headline and its Details section.
struct ConnectionAlertFacts {
    let prompt: PromptRequest

    var destination: String {
        guard let endpoint = prompt.endpoint else { return "Unavailable" }
        let host = endpoint.hostname?.ascii ?? endpoint.address.description
        return endpoint.port.map { "\(host):\($0)" } ?? host
    }

    var destinationSource: String {
        prompt.endpoint?.hostname == nil ? "IP address" : "Hostname"
    }

    var protocolLabel: String {
        switch prompt.transportProtocol {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .unsupported(let number): "Unsupported (\(number))"
        }
    }

    var ownerLabel: String {
        switch prompt.owner {
        case .user: "Current user"
        case .system: "System process (affects all users)"
        case .unknown: "Unknown owner"
        }
    }

    var identityTitle: String {
        switch prompt.appIdentity ?? prompt.processIdentity {
        case .applePlatform: "Apple software"
        case .developerID: "App from an identified developer"
        case .appStore: "Mac App Store app"
        case .otherSigner: "Signed app"
        case .adHoc: "Ad hoc signed app"
        case .unsigned: "Unsigned app"
        case nil: "Unknown app"
        }
    }

    var identitySymbol: String {
        switch prompt.appIdentity ?? prompt.processIdentity {
        case .applePlatform, .developerID, .appStore: "checkmark.seal"
        case .otherSigner: "signature"
        case .adHoc, .unsigned, nil: "exclamationmark.triangle"
        }
    }

    func identityEvidence(for identity: ProcessIdentity) -> String {
        switch identity {
        case .applePlatform(let value), .developerID(let value), .appStore(let value):
            return "\(value.teamIdentifier ?? "No Team ID") • \(value.signingIdentifier)"
        case .otherSigner(_, let identifier): return identifier
        case .adHoc: return "Identified only by this exact build of the app."
        case .unsigned(let path, _): return path
        }
    }

    func signer(for identity: ProcessIdentity) -> String { Self.signerLabel(for: identity) }

    /// Who vouches for the code, as the Details section names it.
    static func signerLabel(for identity: ProcessIdentity) -> String {
        switch identity {
        case .applePlatform: "Apple"
        case .developerID(let value):
            "Developer ID, team \(DisplaySanitizer.plainText(value.teamIdentifier ?? "unknown"))"
        case .appStore: "Mac App Store"
        case .otherSigner: "A certificate Apple didn’t issue"
        case .adHoc: "Ad hoc (signed only by itself)"
        case .unsigned: "Not signed"
        }
    }

    /// The fingerprint Rift matches rules against, when there is one.
    func fingerprint(for identity: ProcessIdentity) -> String? {
        switch identity {
        case .applePlatform, .developerID, .appStore: nil
        case .otherSigner(let key, _): "Certificate key SHA-256 \(key)"
        case .adHoc(let hash): "Code hash \(hash)"
        case .unsigned(_, let hash): "File SHA-256 \(hash)"
        }
    }
}

struct ConnectionAlertDetails: View {
    let prompt: PromptRequest
    let controller: ControlPlaneController
    @State private var ruleSummaries: [(id: UUID, text: String)] = []

    private var facts: ConnectionAlertFacts { ConnectionAlertFacts(prompt: prompt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                row("Destination", facts.destination)
                row("Identified by", facts.destinationSource)
                row("Direction", prompt.direction == .outgoing ? "Outgoing" : "Incoming")
                row("Protocol", facts.protocolLabel)
                row("Owner", facts.ownerLabel)
            }
            if let appIdentity = prompt.appIdentity {
                identity("App", appIdentity)
            }
            if let processIdentity = prompt.processIdentity,
               processIdentity != prompt.appIdentity {
                identity("Helper process", processIdentity)
            }
            ConnectionExplanationView(
                identity: prompt.processIdentity ?? prompt.appIdentity,
                fallbackName: MonitorQuery.identityLabel(prompt.appIdentity ?? prompt.processIdentity),
                host: prompt.endpoint?.hostname?.ascii ?? prompt.endpoint?.address.description
            )
            if !ruleSummaries.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Rules that apply").foregroundStyle(.secondary)
                    ForEach(ruleSummaries, id: \.id) { summary in
                        Text(summary.text)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .padding(.top, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: prompt.affectingRuleIDs) {
            ruleSummaries = await controller.ruleSummaries(prompt.affectingRuleIDs)
        }
    }

    private func identity(_ title: String, _ identity: ProcessIdentity) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            LabeledContent(
                title,
                value: DisplaySanitizer.plainText(facts.identityEvidence(for: identity))
            )
            Text("Signed by: \(facts.signer(for: identity))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let fingerprint = facts.fingerprint(for: identity) {
                Text(fingerprint)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(DisplaySanitizer.plainText(value)).textSelection(.enabled)
        }
    }
}

/// Reasons to look twice, shown above the alert's choices.
struct ConnectionAlertWarningList: View {
    let warnings: [ConnectionAlertWarning]

    var body: some View {
        if !warnings.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(warnings, id: \.self) { warning in
                    Label(warning.message, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Return allows and Esc blocks, like the default and cancel buttons of a
/// dialog, and ⌘A and ⌘B work even while the note is being typed. The
/// buttons are invisible so every key goes through the same guard as the
/// others. When the alert carries a warning, Return does nothing, so allowing
/// takes a click or ⌘A.
struct ConnectionAlertKeys: View {
    let allow: () -> Void
    let block: () -> Void
    var returnAllows = true
    var noteFocused = false

    var body: some View {
        ZStack {
            // Return and Esc belong to the note while it's being typed.
            Button("Allow", action: allow).keyboardShortcut(.defaultAction)
                .disabled(!returnAllows || noteFocused)
            Button("Block", action: block).keyboardShortcut(.cancelAction)
                .disabled(noteFocused)
            Button("Allow", action: allow).keyboardShortcut("a", modifiers: .command)
            Button("Block", action: block).keyboardShortcut("b", modifiers: .command)
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }
}

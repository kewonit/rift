import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

/// Plain facts about one alert, shared by its headline and its Details section.
struct ConnectionAlertFacts {
    let prompt: PromptRequest

    var destination: String {
        guard let endpoint = prompt.endpoint else { return String(localized: "Unavailable") }
        let host = endpoint.hostname?.ascii ?? endpoint.address.description
        return endpoint.port.map { "\(host):\($0)" } ?? host
    }

    var destinationSource: String {
        prompt.endpoint?.hostname == nil ? String(localized: "IP address") : String(localized: "Hostname")
    }

    var protocolLabel: String {
        switch prompt.transportProtocol {
        case .tcp: "TCP"
        case .udp: "UDP"
        case .unsupported(let number): String(localized: "Unsupported (\(String(number)))")
        }
    }

    var ownerLabel: String {
        switch prompt.owner {
        case .user: String(localized: "Current user")
        case .system: String(localized: "System process (affects all users)")
        case .unknown: String(localized: "Unknown owner")
        }
    }

    var identityTitle: String {
        switch prompt.appIdentity ?? prompt.processIdentity {
        case .applePlatform: String(localized: "Apple software")
        case .developerID: String(localized: "App from an identified developer")
        case .appStore: String(localized: "Mac App Store app")
        case .otherSigner: String(localized: "Signed app")
        case .adHoc: String(localized: "Ad hoc signed app")
        case .unsigned: String(localized: "Unsigned app")
        case nil: String(localized: "Unknown app")
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
            return "\(value.teamIdentifier ?? String(localized: "No Team ID")) • \(value.signingIdentifier)"
        case .otherSigner(_, let identifier): return identifier
        case .adHoc: return String(localized: "Identified only by this exact build of the app.")
        case .unsigned(let path, _): return path
        }
    }

    func signer(for identity: ProcessIdentity) -> String { Self.signerLabel(for: identity) }

    /// Who vouches for the code, as the Details section names it.
    static func signerLabel(for identity: ProcessIdentity) -> String {
        switch identity {
        case .applePlatform: "Apple"
        case .developerID(let value):
            value.teamIdentifier.map { String(localized: "Developer ID, team \(DisplaySanitizer.plainText($0))") }
                ?? String(localized: "Developer ID, team unknown")
        case .appStore: "Mac App Store"
        case .otherSigner: String(localized: "A certificate Apple didn’t issue")
        case .adHoc: String(localized: "Ad hoc (signed only by itself)")
        case .unsigned: String(localized: "Not signed")
        }
    }

    /// The fingerprint Rift matches rules against, when there is one.
    func fingerprint(for identity: ProcessIdentity) -> String? {
        switch identity {
        case .applePlatform, .developerID, .appStore: nil
        case .otherSigner(let key, _): String(localized: "Certificate key SHA-256 \(key.description)")
        case .adHoc(let hash): String(localized: "Code hash \(hash.description)")
        case .unsigned(_, let hash): String(localized: "File SHA-256 \(hash.description)")
        }
    }
}

struct ConnectionAlertDetails: View {
    let prompt: PromptRequest
    let controller: ControlPlaneController
    var developer: DeveloperExplanation?
    @State private var ruleSummaries: [(id: UUID, text: String)] = []

    private var facts: ConnectionAlertFacts { ConnectionAlertFacts(prompt: prompt) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 7) {
                row("Destination", facts.destination)
                row("Identified by", facts.destinationSource)
                row("Direction", prompt.direction == .outgoing ? String(localized: "Outgoing") : String(localized: "Incoming"))
                row("Protocol", facts.protocolLabel)
                row("Owner", facts.ownerLabel)
                ForEach(ProcessDetailsPresentation.rows(for: prompt.processes)) { process in
                    GridRow {
                        Text(process.title).foregroundStyle(.secondary)
                        Text(process.value)
                            .font(process.isPath ? .callout.monospaced() : .body)
                            .lineLimit(process.isPath ? 2 : 1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(process.isPath ? process.value : "")
                    }
                }
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
                host: prompt.endpoint?.hostname?.ascii ?? prompt.endpoint?.address.description,
                developer: developer
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

    private func identity(_ title: LocalizedStringKey, _ identity: ProcessIdentity) -> some View {
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

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
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
                        .accessibilityLabel("Warning: \(warning.message)")
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
///
/// Single keys choose how long the answer lasts and open the details, as in
/// other firewalls: O only this time, 5 five minutes, H one hour, F always,
/// D details. They're off while the note is being typed.
struct ConnectionAlertKeys: View {
    static let lifetimeKeys: [(key: Character, lifetime: AlertLifetime)] = [
        ("o", .once), ("5", .fiveMinutes), ("h", .oneHour), ("f", .permanent),
    ]
    static let help = String(
        localized: "Keys: O only this time, 5 five minutes, H one hour, F always, D details",
        comment: "The letters are the keys to press, so they stay O, 5, H, F and D in every language"
    )

    let allow: () -> Void
    let block: () -> Void
    var returnAllows = true
    var noteFocused = false
    /// Nil while a lasting answer isn't on offer.
    var lifetime: Binding<AlertLifetime>?
    var toggleDetails: () -> Void = {}

    var body: some View {
        ZStack {
            ForEach(Self.lifetimeKeys, id: \.key) { item in
                Button(item.lifetime.menuTitle) { lifetime?.wrappedValue = item.lifetime }
                    .keyboardShortcut(KeyEquivalent(item.key), modifiers: [])
                    .disabled(lifetime == nil || noteFocused)
            }
            Button("Details", action: toggleDetails)
                .keyboardShortcut("d", modifiers: [])
                .disabled(noteFocused)
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

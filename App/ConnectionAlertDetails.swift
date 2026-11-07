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
}

struct ConnectionAlertDetails: View {
    let prompt: PromptRequest

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
                LabeledContent(
                    "Application",
                    value: DisplaySanitizer.plainText(facts.identityEvidence(for: appIdentity))
                )
            }
            if let processIdentity = prompt.processIdentity,
               processIdentity != prompt.appIdentity {
                LabeledContent(
                    "Helper process",
                    value: DisplaySanitizer.plainText(facts.identityEvidence(for: processIdentity))
                )
            }
        }
        .padding(.top, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(DisplaySanitizer.plainText(value)).textSelection(.enabled)
        }
    }
}

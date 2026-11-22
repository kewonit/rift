import AppKit
import RiftControl
import RiftCore
import RiftIPC
import SwiftUI

/// What a connection's app is, from Rift's own notes or from the policy its
/// developer ships with the app, and a way to look it up on the web.
struct ConnectionExplanationView: View {
    let identity: ProcessIdentity?
    let fallbackName: String
    let host: String?
    /// What the app's developer says, or nil when the app ships no policy.
    var developer: DeveloperExplanation?
    /// The Map shows what blocking would break up front; the alert shows it
    /// when Block is pressed.
    var showsConsequences = false

    var body: some View {
        let note = ProcessNotes.shared.note(for: identity)
        let search = ConnectionWebSearch.url(identity: identity, fallbackName: fallbackName, host: host)
        if note != nil || search != nil || developer != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let note {
                    Text("About this service").font(.caption).foregroundStyle(.secondary)
                    Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if let developer {
                    DeveloperExplanationText(explanation: developer, showsConsequences: showsConsequences)
                }
                if let search {
                    Button("Search the Web") { NSWorkspace.shared.open(search) }
                        .buttonStyle(.link)
                        .help("Opens a web search for this app and destination in your browser")
                }
            }
        }
    }
}

/// The developer's own words, marked as theirs.
struct DeveloperExplanationText: View {
    let explanation: DeveloperExplanation
    var showsConsequences = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("From the app’s developer").font(.caption).foregroundStyle(.secondary)
                .help("From the Internet Access Policy the developer ships inside the app. Rift reads it from disk and checks the app’s signature covers it.")
            if explanation.describesConnection {
                ForEach(explanation.connections, id: \.self) { connection in
                    Text(DisplaySanitizer.plainText(connection.purpose))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    ForEach(connection.services, id: \.self) { service in
                        Text(DisplaySanitizer.plainText("\(service.name): \(service.purpose)"))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if showsConsequences, !explanation.denyConsequences.isEmpty {
                    Text("If you block it").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
                    ForEach(explanation.denyConsequences, id: \.self) { consequence in
                        Text(DisplaySanitizer.plainText(consequence))
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("The developer’s policy doesn’t mention this connection.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// What the developer says blocking would break, shown once Block is pressed
/// so the person can choose Block Anyway or answer differently.
struct ConnectionAlertBlockConsequences: View {
    let consequences: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("The developer says blocking this means:", systemImage: "exclamationmark.bubble")
                .font(.callout.weight(.medium))
            ForEach(consequences, id: \.self) { consequence in
                Text(DisplaySanitizer.plainText(consequence))
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            Text("Choose Block Anyway to block it.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(RiftDesign.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .systemOrange).opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// "First time this app has connected to example.com", from history on this
/// Mac. Nothing is looked up, and the line is left out when history is off
/// or too young to say.
struct ConnectionAlertFirstContact: View {
    let prompt: PromptRequest
    let domain: String?
    let controller: ControlPlaneController
    @State private var isFirst = false

    var body: some View {
        Group {
            if isFirst, let domain {
                Label(HistoryFirstContact.sentence(domain: domain), systemImage: "sparkle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("From your connection history on this Mac")
            }
        }
        .task(id: prompt.nonce) {
            isFirst = false
            guard controller.persistentHistoryEnabled, let domain, let history = controller.history,
                  let identity = prompt.appIdentity ?? prompt.processIdentity else { return }
            let first = try? await history.isFirstContact(
                app: identity, domain: domain, before: prompt.observedAt, excluding: prompt.flowID
            )
            guard !Task.isCancelled else { return }
            isFirst = first == true
        }
    }
}

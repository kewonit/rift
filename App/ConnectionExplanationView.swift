import AppKit
import RiftControl
import RiftCore
import SwiftUI

/// What a connection's app is, from Rift's own notes, and a way to look it
/// up on the web.
struct ConnectionExplanationView: View {
    let identity: ProcessIdentity?
    let fallbackName: String
    let host: String?

    var body: some View {
        let note = ProcessNotes.shared.note(for: identity)
        let search = ConnectionWebSearch.url(identity: identity, fallbackName: fallbackName, host: host)
        if note != nil || search != nil {
            VStack(alignment: .leading, spacing: 3) {
                if let note {
                    Text("About this service").font(.caption).foregroundStyle(.secondary)
                    Text(note).font(.callout).fixedSize(horizontal: false, vertical: true)
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

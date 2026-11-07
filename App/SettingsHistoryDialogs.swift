import RiftControl
import SwiftUI

/// The confirmations for connection history, kept apart from the Settings view.
struct SettingsHistoryDialogs: ViewModifier {
    @Binding var pendingExport: HistoryExportFormat?
    @Binding var showingDisableChoice: Bool
    @Binding var showingClearConfirmation: Bool
    let export: () -> Void
    let turnOff: (_ clearHistory: Bool, _ clearUsage: Bool) -> Void
    let keepOn: () -> Void
    let clear: (_ clearUsage: Bool) -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Export connection history?",
                isPresented: Binding(
                    get: { pendingExport != nil },
                    set: { if !$0 { pendingExport = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Export", action: export)
                Button("Cancel", role: .cancel) { pendingExport = nil }
            } message: {
                Text("The file can include app names, destinations, ports, and connection times. Share it with care.")
            }
            .confirmationDialog(
                "Turn off connection history?",
                isPresented: $showingDisableChoice,
                titleVisibility: .visible
            ) {
                Button("Turn Off and Keep History") { turnOff(false, false) }
                Button("Turn Off and Clear History", role: .destructive) { turnOff(true, false) }
                Button("Turn Off and Clear History and Rule Usage", role: .destructive) { turnOff(true, true) }
                Button("Cancel", role: .cancel, action: keepOn)
            } message: {
                Text("Rift will stop saving new connections.")
            }
            .confirmationDialog(
                "Clear connection history?",
                isPresented: $showingClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear History Only", role: .destructive) { clear(false) }
                Button("Clear History and Rule Usage", role: .destructive) { clear(true) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can’t be undone. Your rules and settings aren’t affected.")
            }
    }
}

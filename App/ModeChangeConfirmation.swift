import Foundation
import RiftControl
import RiftCore
import SwiftUI

/// Remembers the mode to return to after rules are paused.
enum PausedModeMemory {
    private static let key = "statusPreviousFilteringMode"

    static func remember(_ mode: OperationMode) {
        guard mode != .filterOff, mode != .degradedFallback else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: key)
    }

    static var resumeMode: OperationMode {
        UserDefaults.standard.string(forKey: key).flatMap(OperationMode.init(rawValue:)) ?? .silentAllow
    }
}

/// The one confirmation for risky modes, so a change warns the same way
/// wherever it's made.
struct ModeChangeConfirmation: ViewModifier {
    @Binding var pendingMode: OperationMode?
    let confirm: (OperationMode) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            pendingMode?.confirmationTitle ?? "",
            isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
            titleVisibility: .visible,
            presenting: pendingMode
        ) { mode in
            Button("Switch to \(mode.displayName)") {
                pendingMode = nil
                confirm(mode)
            }
            Button("Cancel", role: .cancel) { pendingMode = nil }
        } message: { mode in
            Text(mode.confirmationMessage)
        }
    }
}

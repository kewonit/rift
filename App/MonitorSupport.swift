import RiftControl
import SwiftUI

func monitorCoveragePending(_ state: MonitorRuleCoverageState) -> Bool {
    state == .savedPendingEnforcement || state == .persistedPendingProvider
        || state == .applyFailed
}

func monitorCoverageLabel(_ state: MonitorRuleCoverageState) -> String {
    switch state {
    case .exact: String(localized: "Matched by an exact rule")
    case .broader: String(localized: "Matched by a broader rule")
    case .narrower: String(localized: "Partly covered by rules")
    case .mixed: String(localized: "Covered by different rules")
    case .savedPendingEnforcement: String(localized: "Rule saved, waiting for the filter")
    case .persistedPendingProvider: String(localized: "Rule saved, waiting for the filter")
    case .applyFailed: String(localized: "Rule couldn’t be applied")
    case .unresolved: String(localized: "No rule decided this")
    case .policyChanged: String(localized: "Rules changed since this connection")
    case .historicalRuleMissing: String(localized: "The rule that decided this was removed")
    case .identityChanged: String(localized: "The app’s identity changed")
    case .hostnameUnavailable: String(localized: "Hostname unavailable")
    case .noRule: String(localized: "No matching rule")
    }
}

/// Confirms an allow rule that overrides the user's blocklists.
struct MonitorManagedListOverrideConfirmation: ViewModifier {
    @Binding var pending: MonitorHierarchyNode?
    let confirm: (MonitorHierarchyNode) -> Void

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Allow this blocklisted connection?",
            isPresented: Binding(
                get: { pending != nil },
                set: { if !$0 { pending = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let pending {
                Button("Allow This Connection") {
                    self.pending = nil
                    confirm(pending)
                }
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            Text("This allows only this app and destination, and overrides your blocklists for them.")
        }
    }
}

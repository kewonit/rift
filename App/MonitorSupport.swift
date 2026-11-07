import RiftControl
import SwiftUI

func monitorCoveragePending(_ state: MonitorRuleCoverageState) -> Bool {
    state == .savedPendingEnforcement || state == .persistedPendingProvider
        || state == .applyFailed
}

func monitorCoverageLabel(_ state: MonitorRuleCoverageState) -> String {
    switch state {
    case .exact: "Matched by an exact rule"
    case .broader: "Matched by a broader rule"
    case .narrower: "Partly covered by rules"
    case .mixed: "Covered by different rules"
    case .savedPendingEnforcement: "Rule saved, waiting for the filter"
    case .persistedPendingProvider: "Rule saved, waiting for the filter"
    case .applyFailed: "Rule couldn’t be applied"
    case .unresolved: "Decided by default"
    case .policyChanged: "Rules changed since this connection"
    case .historicalRuleMissing: "The rule that decided this was removed"
    case .identityChanged: "The app’s identity changed"
    case .hostnameUnavailable: "Hostname unavailable"
    case .noRule: "No matching rule"
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

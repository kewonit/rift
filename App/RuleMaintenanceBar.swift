import RiftControl
import SwiftUI

/// On the Redundant, Unused and Expired lists, says what the list means and
/// deletes everything on it at once. Undo still works.
struct RuleMaintenanceBar: View {
    @Bindable var model: RulesWorkspaceController
    let isPreview: Bool
    @State private var confirming = false

    var body: some View {
        let filter = model.sidebarSelection.listFilter
        let count = model.deletableShownRuleIDs.count
        if let summary = Self.summary(filter, count: count), count > 0 {
            HStack(spacing: 6) {
                Text(summary).lineLimit(2)
                Spacer(minLength: 8)
                Button("Delete All…") { confirming = true }
                    .controlSize(.small)
                    .disabled(isPreview || model.historyCommandIsRunning)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.bar)
            .confirmationDialog(
                count == 1 ? "Delete 1 rule?" : "Delete \(count) rules?",
                isPresented: $confirming
            ) {
                Button(count == 1 ? "Delete Rule" : "Delete \(count) Rules", role: .destructive) {
                    Task { await model.deleteAllShown() }
                }
            } message: {
                Text("You can undo this right after.")
            }
        }
    }

    static func summary(_ filter: RuleListFilter, count: Int) -> String? {
        return switch filter {
        case .redundant: String(localized: "\(count) rules change nothing, because other rules already decide everything they match.")
        case .unused: String(localized: "\(count) rules haven’t matched a connection since history began.")
        case .expired: String(localized: "\(count) rules expired and no longer apply.")
        default: nil
        }
    }
}

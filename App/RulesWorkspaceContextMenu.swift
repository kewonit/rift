import RiftControl
import RiftCore
import AppKit
import SwiftUI

extension RulesWorkspaceTable {
    @ViewBuilder
    func contextMenuItems(_ ids: Set<RuleWorkspaceNodeID>) -> some View {
        Button("New Rule…") { showingEditor = true }
            .disabled(isPreview)
        Divider()
        Button("Edit") {
            let selected = applySelection(ids)
            editingRow = selected.count == 1 ? row(selected.first) : nil
        }
        .disabled(isPreview || !selectionIsEditable(ids))
        Button("Duplicate") {
            applySelection(ids)
            Task { await model.duplicateSelected() }
        }
        .disabled(isPreview || !selectionIsEditable(ids))
        Button("Enable") {
            applySelection(ids)
            Task { await model.setSelectedEnabled(true) }
        }
        .disabled(isPreview || eligibleCount(ids) == 0)
        Button("Disable") {
            applySelection(ids)
            Task { await model.setSelectedEnabled(false) }
        }
        .disabled(isPreview || eligibleCount(ids) == 0)
        Button("Mark Reviewed") {
            applySelection(ids)
            Task { await model.markSelectedReviewed(true) }
        }
        .disabled(isPreview || eligibleCount(ids) == 0)
        Button("Mark Unreviewed") {
            applySelection(ids)
            Task { await model.markSelectedReviewed(false) }
        }
        .disabled(isPreview || eligibleCount(ids) == 0)
        Menu("Assign to Group") {
            Button("No Group") {
                applySelection(ids)
                Task { await model.assignSelectedToGroup(nil) }
            }
            ForEach(model.groups) { group in
                Button(group.name) {
                    applySelection(ids)
                    Task { await model.assignSelectedToGroup(group.id) }
                }
            }
        }
        .disabled(isPreview || eligibleCount(ids) == 0)
        Menu("Assign to Profile") {
            Button("All Profiles") {
                applySelection(ids)
                Task { await model.assignSelectedToProfile(nil) }
            }
            ForEach(model.profiles) { profile in
                Button(profile.name) {
                    applySelection(ids)
                    Task { await model.assignSelectedToProfile(profile.id) }
                }
            }
        }
        .disabled(isPreview || eligibleCount(ids) == 0)
        Divider()
        Button("Show Rules for This App") { focusAffectingRules(ids) }
            .disabled(selectedApplicationIdentity(ids) == nil)
        Button("Show App in Finder") { revealApplication(ids) }
            .disabled(isPreview || selectedApplicationIdentity(ids) == nil)
        Button("Copy Details") { copyDetails(ids) }
            .disabled(isPreview || selectedRows(ids).count != 1)
        Divider()
        Button("Delete…", role: .destructive) {
            applySelection(ids)
            showingDeleteConfirmation = true
        }
        .disabled(isPreview || eligibleCount(ids) == 0)
        let skipped = selectedRuleIDs(ids).count - eligibleCount(ids)
        if skipped > 0 {
            Text(skipped == 1
                ? "1 protected or blocklist rule will be skipped."
                : "\(skipped) protected or blocklist rules will be skipped.")
        }
    }
}

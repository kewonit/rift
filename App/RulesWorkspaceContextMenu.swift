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
        if eligibleCount(ids) > 1 {
            Button("Edit Rules…") {
                applySelection(ids)
                model.bulkEditing = true
            }
            .disabled(isPreview)
        } else {
            Button("Edit") {
                let selected = applySelection(ids)
                editingRow = selected.count == 1 ? row(selected.first) : nil
            }
            .disabled(isPreview || !selectionIsEditable(ids))
        }
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
        Button("Make Permanent") {
            applySelection(ids)
            Task { await model.makeSelectedPermanent() }
        }
        .disabled(isPreview || !selectedRows(ids).contains { $0.rule.expiresAt != nil })
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
        Button("Show on Map") { showOnMap(ids) }
            .disabled(isPreview || selectedApplicationIdentity(ids) == nil)
        Button("Show App in Finder") { revealApplication(ids) }
            .disabled(isPreview || selectedApplicationIdentity(ids) == nil)
        Button("Copy Details") { copyDetails(ids) }
            .disabled(isPreview || selectedRows(ids).count != 1)
        Button("Export…") {
            applySelection(ids)
            Task { await model.exportSelected() }
        }
        .disabled(isPreview || !selectedRows(ids).contains { ConfigurationArchiveCodec.isShareable($0.rule) })
        Button("Export as .lsrules…") {
            applySelection(ids)
            Task { await model.exportSelectedAsLSRules() }
        }
        .disabled(isPreview || !selectedRows(ids).contains { ConfigurationArchiveCodec.isShareable($0.rule) })
        .help("Saves the rules in the format other Mac firewalls import. Rules the format can’t express are left out.")
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

    /// The row's main menu commands as VoiceOver actions, so a row can be
    /// edited or deleted without selecting it and opening its menu. They're
    /// worked out from the row alone, because every visible row asks.
    @ViewBuilder
    func rowAccessibilityActions(_ node: RuleWorkspaceNode) -> some View {
        let ids: Set<RuleWorkspaceNodeID> = [node.id]
        let editable = rows(node).filter {
            !$0.rule.flags.contains(.protected) && !$0.rule.flags.contains(.sourceManaged)
        }
        let apps = Set(rows(node).compactMap { applicationIdentity($0.rule.process) })
        if !isPreview, editable.count == 1, rows(node).count == 1 {
            Button("Edit") { editingRow = row(applySelection(ids).first) }
        } else if !isPreview, editable.count > 1 {
            Button("Edit Rules…") {
                applySelection(ids)
                model.bulkEditing = true
            }
        }
        if !isPreview, !editable.isEmpty {
            Button("Delete…") {
                applySelection(ids)
                showingDeleteConfirmation = true
            }
        }
        if apps.count == 1 {
            Button("Show Rules for This App") { focusAffectingRules(ids) }
            if !isPreview {
                Button("Show on Map") { showOnMap(ids) }
            }
        }
    }
}

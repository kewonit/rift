import AppKit
import RiftControl
import RiftCore
import SwiftUI

extension MonitorFeed {
    // MARK: Selection

    func selectionDidChange() {
        let node = selectionID.flatMap { MonitorHierarchyBuilder.node(withID: $0, in: hierarchy) }
        if selectedNode != node { selectedNode = node }
        if let eventID = node?.eventID ?? node?.ruleSeedEventID { selectedEventID = eventID }
        if selectionID == nil { selectedEventID = nil }
    }

    /// Keeps the same connection selected when a refresh rebuilds the tree.
    func restoreSelection() {
        if let selectedEventID,
           let node = MonitorHierarchyBuilder.node(forEventID: selectedEventID, in: hierarchy) {
            if selectionID != node.id { selectionID = node.id } else { selectionDidChange() }
        } else if selectionID.flatMap({ MonitorHierarchyBuilder.node(withID: $0, in: hierarchy) }) == nil {
            selectionID = nil
        } else {
            selectionDidChange()
        }
    }

    /// Selects a connection another surface asked for (the menu panel, a
    /// notification, or a `rift://activity` link).
    func acceptRequestedSelection() {
        guard let target = session.requestedMonitorEventID else { return }
        if displayed.contains(where: { $0.source.id == target }),
           let node = MonitorHierarchyBuilder.node(forEventID: target, in: hierarchy) {
            selectedEventID = target
            selectionID = node.id
            session.requestedMonitorEventID = nil
            return
        }
        if loadedRowsContain(target) {
            query.clearExcludingFilters()
        } else if rowsAreCompleteForRequest {
            loadError = "That connection is no longer available. It may have been removed from history or hidden by a rule."
            session.requestedMonitorEventID = nil
        }
    }

    // MARK: Rules

    func apply(_ action: FilterAction, to node: MonitorHierarchyNode, elevatedOverrideConfirmed: Bool = false) {
        guard let eventID = node.ruleSeedEventID, let row = rowLookup[eventID] else { return }
        applyingEventID = eventID
        Task {
            defer { applyingEventID = nil }
            do {
                try await session.controlPlane.applyExactMonitorRule(
                    for: row, action: action, elevatedOverrideConfirmed: elevatedOverrideConfirmed
                )
                loadError = nil
                requestPresentationRefresh()
            } catch ControlPlaneController.RuleCommandError.elevatedOverrideRequiresConfirmation {
                pendingManagedListOverride = node
                loadError = nil
            } catch {
                loadError = "The rule wasn’t added. Try again after Rift reconnects."
            }
        }
    }

    func confirmManagedListOverride(_ node: MonitorHierarchyNode) {
        apply(.allow, to: node, elevatedOverrideConfirmed: true)
    }

    func showRules(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        session.requestedRuleIDs = ids
        session.destination = .rules
    }
}

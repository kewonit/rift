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
            session.controlPlane.actionResults.post(
                "That connection is no longer available. It may have been removed from history or hidden by a rule.",
                tone: .failure
            )
            session.requestedMonitorEventID = nil
        }
    }

    // MARK: Rules

    func apply(_ action: FilterAction, to node: MonitorHierarchyNode, elevatedOverrideConfirmed: Bool = false) {
        guard let eventID = node.ruleSeedEventID, let row = rowLookup[eventID] else { return }
        applyingEventID = eventID
        let results = session.controlPlane.actionResults
        Task {
            defer { applyingEventID = nil }
            do {
                let change = try await session.controlPlane.applyExactMonitorRule(
                    for: row, action: action, elevatedOverrideConfirmed: elevatedOverrideConfirmed
                )
                await report(change, action: action, row: row)
                requestPresentationRefresh()
            } catch ControlPlaneController.RuleCommandError.elevatedOverrideRequiresConfirmation {
                pendingManagedListOverride = node
            } catch ControlPlaneController.RuleCommandError.overriddenByRule(let ruleID) {
                results.post(
                    "Nothing changed, because another rule still decides this connection.",
                    tone: .failure,
                    ruleIDs: ruleID.map { [$0] } ?? []
                )
            } catch {
                results.post("The rule wasn’t added. Try again after Rift reconnects.", tone: .failure)
            }
        }
    }

    private func report(
        _ change: ControlPlaneController.MonitorRuleChange,
        action: FilterAction,
        row: MonitorEventRow
    ) async {
        let results = session.controlPlane.actionResults
        guard let result = change.result else {
            results.post(
                action == .deny ? "This connection is already blocked." : "This connection is already allowed.",
                ruleIDs: change.ruleIDs
            )
            return
        }
        let flow = row.event.flow
        var application = MonitorQuery.applicationLabel(row)
        if let identity = flow.sourceAppIdentity ?? flow.sourceProcessIdentity,
           let name = await session.applicationArtwork.artwork(for: identity)?.displayName {
            application = name
        }
        let sentence = RulePlainLanguage.change(
            action: action,
            application: DisplaySanitizer.plainText(application),
            destination: DisplaySanitizer.plainText(MonitorQuery.hostnameLabel(row)),
            port: flow.destinationEndpoint?.port,
            incoming: flow.direction == .incoming
        )
        results.post(
            result.requiresAttention ? "\(sentence) \(result.message)" : sentence,
            tone: result.requiresAttention ? .pending : .success,
            ruleIDs: change.ruleIDs,
            offersUndo: true
        )
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

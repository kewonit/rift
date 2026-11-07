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

    /// The connections a row stands for. A group's rule is built from its
    /// most recent connection.
    func rows(in node: MonitorHierarchyNode) -> [MonitorEventRow] {
        node.eventIDs.compactMap { rowLookup[$0] }
            .sorted { $0.event.occurredAt > $1.event.occurredAt }
    }

    func canDecide(_ node: MonitorHierarchyNode) -> Bool {
        !MonitorRuleScope.options(for: node.eventIDs.compactMap { rowLookup[$0] }).isEmpty
    }

    /// Opens the scope chooser, so the person sees what a rule covers first.
    func requestRule(_ action: FilterAction, for node: MonitorHierarchyNode) {
        let members = rows(in: node)
        let options = MonitorRuleScope.options(for: members)
        guard let row = members.first, !options.isEmpty else { return }
        Task {
            pendingRuleRequest = MonitorRuleRequest(
                action: action, node: node, row: row, options: options,
                application: await applicationName(for: row)
            )
        }
    }

    func applyRule(
        _ request: MonitorRuleRequest,
        breadth: MonitorRuleBreadth,
        duration: MonitorRuleDuration,
        elevatedOverrideConfirmed: Bool = false
    ) {
        applyingEventID = request.row.id
        let results = session.controlPlane.actionResults
        Task {
            defer { applyingEventID = nil }
            do {
                let change = try await session.controlPlane.applyMonitorRule(
                    for: request.row, action: request.action, breadth: breadth, duration: duration,
                    elevatedOverrideConfirmed: elevatedOverrideConfirmed
                )
                report(change, request: request, breadth: breadth, duration: duration)
                requestPresentationRefresh()
            } catch ControlPlaneController.RuleCommandError.elevatedOverrideRequiresConfirmation {
                pendingOverrideChoice = (request, breadth, duration)
                pendingManagedListOverride = request.node
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
        request: MonitorRuleRequest,
        breadth: MonitorRuleBreadth,
        duration: MonitorRuleDuration
    ) {
        let results = session.controlPlane.actionResults
        guard let result = change.result else {
            results.post(
                request.action == .deny ? "This is already blocked." : "This is already allowed.",
                ruleIDs: change.ruleIDs
            )
            return
        }
        let sentence = RulePlainLanguage.change(
            action: request.action,
            application: request.application,
            destination: MonitorRuleScope.phrase(breadth, host: request.host),
            port: breadth == .exactConnection ? request.port : nil,
            incoming: request.row.event.flow.direction == .incoming,
            forOneHour: duration == .oneHour
        )
        results.post(
            result.requiresAttention ? "\(sentence) \(result.message)" : sentence,
            tone: result.requiresAttention ? .pending : .success,
            ruleIDs: change.ruleIDs,
            offersUndo: true
        )
    }

    private func applicationName(for row: MonitorEventRow) async -> String {
        let flow = row.event.flow
        if let identity = flow.sourceAppIdentity ?? flow.sourceProcessIdentity,
           let name = await session.applicationArtwork.artwork(for: identity)?.displayName {
            return DisplaySanitizer.plainText(name)
        }
        return DisplaySanitizer.plainText(MonitorQuery.applicationLabel(row))
    }

    func confirmManagedListOverride(_ node: MonitorHierarchyNode) {
        guard let choice = pendingOverrideChoice else { return }
        pendingOverrideChoice = nil
        applyRule(
            choice.request, breadth: choice.breadth, duration: choice.duration,
            elevatedOverrideConfirmed: true
        )
    }

    /// Opens the rule that decides this connection, or every matching rule when
    /// no single one does.
    func showRules(for node: MonitorHierarchyNode) {
        showRules(node.ruleCoverage.winningRuleID.map { [$0] } ?? node.ruleCoverage.ruleIDs)
    }

    func showRules(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        session.requestedRuleIDs = ids
        session.destination = .rules
    }
}

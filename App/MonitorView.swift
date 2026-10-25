import RiftControl
import RiftCore
import AppKit
import SwiftUI

struct MonitorView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var session: AppSession
    @State private var query = MonitorQueryState()
    @State private var queryNow: Date
    @State private var allRows: [MonitorEventRow] = []
    @State private var displayed: [MonitorDisplayRow] = []
    @State private var summary = MonitorSummarySnapshot.empty
    @State private var rowsAreComplete = true
    @State private var historyCoverage = HistoryCoverageSnapshot.unavailable
    @State private var presentationHierarchy: [MonitorHierarchyNode] = []
    @State private var rowLookup: [String: MonitorEventRow] = [:]
    @State private var decisionSnapshot = DecisionBucketSnapshot(buckets: [], coverage: .gap)
    @State private var sourceSnapshot: MonitorRowsSnapshot?
    @State private var sourceTime: MonitorTimeFilter?
    @State private var sourceAnchor: Date?
    @State private var sourceRevision: UInt64?
    @State private var windowIsVisible = false
    @State private var refreshCoordinator = VisualRefreshCoordinator()
    @State private var visibleLimit = 1_000
    @State private var pinnedDisplayRow: MonitorDisplayRow?
    @State private var selectionID: String?
    @State private var selectedEventID: String?
    @State private var applyingEventID: String?
    @State private var pendingManagedListOverride: MonitorHierarchyNode?
    @State private var loading = false
    @State private var loadError: String?
    @State private var showingSummary = true
    @State private var queryTask: Task<Void, Never>?
    @State private var activeQueryRequestID = MonitorQueryRequestID()
    @State private var monitorIsReady = false

    init(session: AppSession) {
        self.session = session
#if DEBUG
        _queryNow = State(initialValue: session.isUIFixture
            ? MonitorFixtureData.referenceNow : Date())
#else
        _queryNow = State(initialValue: Date())
#endif
    }

    private var hierarchy: [MonitorHierarchyNode] {
        presentationHierarchy
    }
    private var selectedNode: MonitorHierarchyNode? {
        selectionID.flatMap { MonitorHierarchyBuilder.node(withID: $0, in: hierarchy) }
    }

    private var selectedRow: MonitorEventRow? {
        guard let eventID = selectedNode?.eventID ?? selectedNode?.ruleSeedEventID else {
            return nil
        }
        return allRows.first { $0.id == eventID }
    }

    var body: some View {
        MonitorSidebarView(
            query: $query,
            selectionID: $selectionID,
            hierarchy: hierarchy,
            rows: rowLookup,
            summary: summary, isPreview: session.isUIFixture,
            controlPlane: session.controlPlane,
            artworkStore: session.applicationArtwork,
            now: queryNow, decisionSnapshot: decisionSnapshot,
            attentionMessage: monitorAttentionMessage(for: session.lifecycle),
            errorMessage: loadError,
            loading: loading,
            hasMore: displayed.count > visibleLimit,
            applyingEventID: applyingEventID,
            availableLenses: MonitorLens.allCases,
            showFilterStatus: session.requestFilterStatus,
            loadMore: loadMore,
            apply: { apply($0, $1) },
            showRules: showRules
        )
        .inspector(isPresented: $showingSummary) {
            MonitorSummaryView(
                summary: summary, selectedNode: selectedNode, selectedRow: selectedRow,
                applyingEventID: applyingEventID, artworkStore: session.applicationArtwork,
                apply: { apply($0, $1) }, showRules: {
                    selectedNode.map { showRules($0.ruleCoverage.ruleIDs) }
                }, isMinimal: session.controlPlane.isMinimalActivity)
            .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
        }
        .toolbar { MonitorToolbarContent(showingSummary: $showingSummary) }
        .sheet(isPresented: $session.showingFilterStatus) {
            if let lifecycle = session.lifecycle {
                FilterStatusView(
                    controller: lifecycle,
                    controlPlane: session.controlPlane
                )
            }
        }
        .modifier(MonitorManagedListOverrideConfirmation(
            pending: $pendingManagedListOverride,
            confirm: { apply(.allow, $0, elevatedOverrideConfirmed: true) }
        ))
        .task { await start() }
        .background(ActivityWindowVisibility(changed: visibilityChanged))
            .modifier(ActivityRefreshSignal(controller: session.controlPlane, changed: { scheduleReload() }))
        .onChange(of: session.controlPlane.persistentHistoryEnabled) { _, _ in
            if session.controlPlane.isMinimalActivity { query.selectTimeFilter(.tenMinutes); releaseActivity() }
            scheduleReload(immediate: true)
        }
        .onChange(of: query) { _, _ in scheduleQueryUpdate() }
        .onChange(of: selectionID) { _, _ in
            if let eventID = selectedNode?.eventID { selectedEventID = eventID }
        }
        .onChange(of: session.requestedMonitorEventID) { _, _ in
            acceptRequestedSelection()
        }
        .onDisappear(perform: stop)
    }

    private func start() async {
        guard !Task.isCancelled else { return }
        if session.controlPlane.isMinimalActivity { query.selectTimeFilter(.tenMinutes) }
        monitorIsReady = true
        scheduleReload(immediate: true)
    }
    private func visibilityChanged(_ visible: Bool) {
        guard visible != windowIsVisible else { return }
        windowIsVisible = visible
        if visible { session.controlPlane.monitorDidAppear() }
        else { session.monitorDidDisappear() }
        if !visible, session.controlPlane.isMinimalActivity { releaseActivity() }
        refreshCoordinator.setVisible(visible)
        if visible { scheduleReload(immediate: true) }
    }

    private func scheduleReload(immediate: Bool = false) {
        guard monitorIsReady else { return }
        if immediate { session.controlPlane.scheduleActivityDrain(immediate: true) }
        refreshCoordinator.request(immediate: immediate) { await refresh(loadSource: true) }
    }

    private func stop() {
        refreshCoordinator.stop()
        queryTask?.cancel()
        if windowIsVisible { session.monitorDidDisappear() }
        if session.controlPlane.isMinimalActivity { releaseActivity() }
        windowIsVisible = false
        monitorIsReady = false
    }

    private func releaseActivity() {
        queryTask?.cancel()
        activeQueryRequestID = MonitorQueryRequestID()
        allRows = []; displayed = []; rowLookup = [:]
        presentationHierarchy = []; summary = .empty
        decisionSnapshot = DecisionBucketSnapshot(buckets: [], coverage: .gap)
        sourceSnapshot = nil; sourceRevision = nil; pinnedDisplayRow = nil
        selectionID = nil; selectedEventID = nil
    }

    private func scheduleQueryUpdate() {
        queryTask?.cancel()
        activeQueryRequestID = MonitorQueryRequestID()
        queryTask = Task {
            do { try await Task.sleep(for: .milliseconds(160)) }
            catch { return }
            guard !Task.isCancelled else { return }
            refreshCoordinator.request(immediate: true) { await refresh(loadSource: false) }
        }
    }

    private func refresh(loadSource: Bool) async {
        guard monitorIsReady, windowIsVisible else { return }
        let interval = ActivityPerformance.signposter.beginInterval("Activity Refresh")
        defer { ActivityPerformance.signposter.endInterval("Activity Refresh", interval) }
        let requestID = activeQueryRequestID
        let state = query
        let revision = session.controlPlane.activityRevision
        let sameRange = sourceTime == state.time && sourceAnchor == state.timeAnchor
        loading = sourceSnapshot == nil
        defer { loading = false }
        do {
#if DEBUG
            let refreshedNow = session.isUIFixture ? queryNow : Date()
#else
            let refreshedNow = Date()
#endif
            let window = state.baseTimeWindow(now: refreshedNow).flatMap {
                MonitorTimeWindow(start: $0.start, end: state.isLiveTimeRange ? nil : $0.end)
            }
            let snapshot: MonitorRowsSnapshot
            if !loadSource, sourceRevision == revision, sameRange, let saved = sourceSnapshot {
                snapshot = saved
            } else {
                snapshot = try await session.controlPlane.monitorRowsSnapshot(
                    window: window, previous: sameRange ? sourceSnapshot : nil
                )
            }
            let result = try await MonitorQueryEvaluator.evaluate(
                rows: snapshot.rows, state: state,
                now: refreshedNow, queryComplete: snapshot.isComplete, coverage: snapshot.coverage
            )
            let pinnedID = session.requestedMonitorEventID ?? pinnedDisplayRow?.id
            var visible = Array(result.displayed.prefix(visibleLimit))
            if let pinnedID, !visible.contains(where: { $0.id == pinnedID }),
               let pinned = result.displayed.first(where: { $0.id == pinnedID }) {
                visible.append(pinned)
            }
            let refreshedCoverage = try await session.controlPlane.monitorRuleCoverage(for: visible.map(\.source))
            let presentation = try await ActivityPresentation.build(
                evaluation: result, rows: snapshot.rows, query: state, now: refreshedNow,
                coverage: snapshot.coverage, isComplete: snapshot.isComplete,
                coverages: refreshedCoverage, visibleLimit: visibleLimit, pinnedID: pinnedID
            )
            guard windowIsVisible, queryMayPublish(requestID) else { return }
            sourceSnapshot = snapshot
            sourceTime = state.time
            sourceAnchor = state.timeAnchor
            sourceRevision = revision
            if allRows != snapshot.rows { allRows = snapshot.rows }
            rowsAreComplete = snapshot.isComplete
            historyCoverage = snapshot.coverage
            queryNow = refreshedNow
            if displayed != result.displayed { displayed = result.displayed }
            pinnedDisplayRow = pinnedID.flatMap { id in result.displayed.first { $0.id == id } }
            if summary != result.summary { summary = result.summary }
            if presentationHierarchy != presentation.hierarchy { presentationHierarchy = presentation.hierarchy }
            if rowLookup != presentation.rowLookup { rowLookup = presentation.rowLookup }
            if decisionSnapshot != presentation.decisions { decisionSnapshot = presentation.decisions }
            restoreSelection()
            loadError = nil
            acceptRequestedSelection()
            signalFixtureReadiness()
        } catch is CancellationError {
        } catch {
            guard windowIsVisible, queryMayPublish(requestID) else { return }
            loadError = "Couldn’t refresh. Showing the last activity Rift loaded."
        }
    }

    private func queryMayPublish(_ requestID: MonitorQueryRequestID) -> Bool {
        MonitorQueryPublication.permits(requestID, active: activeQueryRequestID,
                                        taskIsCancelled: Task.isCancelled)
    }

    private func loadMore() {
        visibleLimit = min(displayed.count, visibleLimit + 1_000)
        refreshCoordinator.request(immediate: true) { await refresh(loadSource: false) }
    }

    private func apply(
        _ action: FilterAction,
        _ node: MonitorHierarchyNode,
        elevatedOverrideConfirmed: Bool = false
    ) {
        guard let eventID = node.ruleSeedEventID,
              let row = allRows.first(where: { $0.id == eventID }) else { return }
        applyingEventID = eventID
        Task {
            do {
                try await session.controlPlane.applyExactMonitorRule(
                    for: row,
                    action: action,
                    elevatedOverrideConfirmed: elevatedOverrideConfirmed
                )
                loadError = nil
                refreshCoordinator.request(immediate: true) { await refresh(loadSource: false) }
            } catch ControlPlaneController.RuleCommandError.elevatedOverrideRequiresConfirmation {
                pendingManagedListOverride = node
                loadError = nil
            } catch {
                loadError = "The rule wasn’t added. Try again after Rift reconnects."
            }
            applyingEventID = nil
        }
    }

    private func showRules(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        session.requestedRuleIDs = ids
        session.destination = .rules
        openWindow(id: "main")
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func acceptRequestedSelection() {
        guard let target = session.requestedMonitorEventID else { return }
        if let index = displayed.firstIndex(where: { $0.source.id == target }) {
            pinnedDisplayRow = displayed[index]
            if let node = MonitorHierarchyBuilder.node(forEventID: target, in: hierarchy) {
                selectionID = node.id
                selectedEventID = target
                session.requestedMonitorEventID = nil
                return
            }
        }
        if allRows.contains(where: { $0.id == target }) {
            query.clearExcludingFilters()
        } else if rowsAreComplete
                    && historyCoverage.coverage(for: .all, now: queryNow) == .complete {
            loadError = "That activity is no longer available. It may have been removed from history or hidden by a rule."
            session.requestedMonitorEventID = nil
        }
    }

    private func restoreSelection() {
        guard let eventID = selectedEventID,
              let node = MonitorHierarchyBuilder.node(forEventID: eventID, in: hierarchy) else {
            if selectionID.flatMap({ MonitorHierarchyBuilder.node(withID: $0, in: hierarchy) }) == nil {
                selectionID = nil
            }
            return
        }
        selectionID = node.id
    }

    private func signalFixtureReadiness() {
#if DEBUG
        guard session.isUIFixture else { return }
        MonitorFixtureData.signalVisualReadiness()
#endif
    }
}

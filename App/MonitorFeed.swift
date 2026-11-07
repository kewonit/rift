import AppKit
import RiftControl
import RiftCore
import SwiftUI

/// The single activity engine behind the Map page. The floating list, the
/// expanded table, the map, the timeline and the inspector all read from it,
/// so there is one query, one refresh pipeline and one selection.
@MainActor
@Observable
final class MonitorFeed {
    // MARK: Query
    var query: MonitorQueryState {
        didSet { if query != oldValue { scheduleQueryUpdate() } }
    }
    var sort: MonitorHierarchySort = .activity {
        didSet { if sort != oldValue { scheduleQueryUpdate() } }
    }
    /// Decision buckets cost a pass over every row; build them only while the
    /// timeline shows decisions.
    var wantsDecisionBuckets = false {
        didSet { if wantsDecisionBuckets, !oldValue { scheduleQueryUpdate() } }
    }

    // MARK: Presentation
    private(set) var now: Date
    private(set) var hierarchy: [MonitorHierarchyNode] = []
    private(set) var displayedCount = 0
    private(set) var displayed: [MonitorDisplayRow] = []
    private(set) var rowLookup: [String: MonitorEventRow] = [:]
    private(set) var summary = MonitorSummarySnapshot.empty
    private(set) var traffic = LiveTrafficSnapshot.empty
    private(set) var decisions = DecisionBucketSnapshot(buckets: [], coverage: .gap)
    private(set) var loading = false
    private(set) var hasMore = false
    private(set) var windowIsVisible = false
    var loadError: String?

    // MARK: Selection and actions
    var selectionID: String? {
        didSet { if selectionID != oldValue { selectionDidChange() } }
    }
    var selectedNode: MonitorHierarchyNode?
    var applyingEventID: String?
    var pendingManagedListOverride: MonitorHierarchyNode?

    var selectedRow: MonitorEventRow? {
        guard let id = selectedNode?.eventID ?? selectedNode?.ruleSeedEventID else { return nil }
        return rowLookup[id]
    }

    var isMinimal: Bool { session.controlPlane.isMinimalActivity }

    /// Whether the loaded rows include `id`, even if filters hide it.
    func loadedRowsContain(_ id: String) -> Bool {
        source?.snapshot.rows.contains { $0.id == id } == true
    }

    /// Whether a missing requested connection is really gone, rather than
    /// outside what Rift has loaded.
    var rowsAreCompleteForRequest: Bool {
        rowsAreComplete && historyCoverage.coverage(for: .all, now: now) == .complete
    }

    @ObservationIgnored let session: AppSession
    @ObservationIgnored private let refreshCoordinator = VisualRefreshCoordinator()
    @ObservationIgnored private var queryTask: Task<Void, Never>?
    @ObservationIgnored private var activeQueryRequestID = MonitorQueryRequestID()
    @ObservationIgnored private var source: SourceCache?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var visibleLimit = 1_000
    @ObservationIgnored private var pinnedEventID: String?
    @ObservationIgnored var selectedEventID: String?
    @ObservationIgnored private var rowsAreComplete = true
    @ObservationIgnored private var historyCoverage = HistoryCoverageSnapshot.unavailable

    private struct SourceCache {
        let snapshot: MonitorRowsSnapshot
        let revision: UInt64
        let time: MonitorTimeFilter
        let anchor: Date?
    }

    init(session: AppSession) {
        self.session = session
        query = MonitorQueryState(time: .tenMinutes)
#if DEBUG
        now = session.isUIFixture ? MonitorFixtureData.referenceNow : Date()
#else
        now = Date()
#endif
    }

    // MARK: Lifecycle

    func start() {
        guard !ready else { return }
        if isMinimal { query.selectTimeFilter(.tenMinutes) }
        ready = true
        scheduleReload(immediate: true)
    }

    func stop() {
        refreshCoordinator.stop()
        queryTask?.cancel()
        if windowIsVisible { session.monitorDidDisappear() }
        if isMinimal { releaseActivity() }
        windowIsVisible = false
        ready = false
    }

    func visibilityChanged(_ visible: Bool) {
        guard visible != windowIsVisible else { return }
        windowIsVisible = visible
        if visible { session.controlPlane.monitorDidAppear() } else { session.monitorDidDisappear() }
        if !visible, isMinimal { releaseActivity() }
        refreshCoordinator.setVisible(visible)
        if visible { scheduleReload(immediate: true) }
    }

    func historyPreferenceChanged() {
        source = nil
        if isMinimal { query.selectTimeFilter(.tenMinutes); releaseActivity() }
        scheduleReload(immediate: true)
    }

    func scheduleReload(immediate: Bool = false) {
        guard ready else { return }
        if immediate { session.controlPlane.scheduleActivityDrain(immediate: true) }
        refreshCoordinator.request(immediate: immediate) { [weak self] in
            await self?.refresh(loadSource: true)
        }
    }

    func loadMore() {
        visibleLimit = min(displayedCount, visibleLimit + 1_000)
        requestPresentationRefresh()
    }

    func requestPresentationRefresh() {
        refreshCoordinator.request(immediate: true) { [weak self] in
            await self?.refresh(loadSource: false)
        }
    }

    private func scheduleQueryUpdate() {
        queryTask?.cancel()
        activeQueryRequestID = MonitorQueryRequestID()
        queryTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.requestPresentationRefresh()
        }
    }

    private func releaseActivity() {
        queryTask?.cancel()
        activeQueryRequestID = MonitorQueryRequestID()
        hierarchy = []; displayed = []; displayedCount = 0; rowLookup = [:]
        summary = .empty; traffic = .empty
        decisions = DecisionBucketSnapshot(buckets: [], coverage: .gap)
        source = nil; pinnedEventID = nil
        selectionID = nil; selectedEventID = nil; selectedNode = nil
    }

    // MARK: Refresh

    private func refresh(loadSource: Bool) async {
        guard ready, windowIsVisible else { return }
        let interval = ActivityPerformance.signposter.beginInterval("Monitor Refresh")
        defer { ActivityPerformance.signposter.endInterval("Monitor Refresh", interval) }
        let requestID = activeQueryRequestID
        let state = query
        let sort = sort
        let includeDecisions = wantsDecisionBuckets
        let revision = session.controlPlane.activityRevision
        let sameRange = source?.time == state.time && source?.anchor == state.timeAnchor
        loading = source == nil
        defer { loading = false }
        do {
#if DEBUG
            let refreshedNow = session.isUIFixture ? now : Date()
#else
            let refreshedNow = Date()
#endif
            let snapshot: MonitorRowsSnapshot
            if !loadSource, let source, source.revision == revision, sameRange {
                snapshot = source.snapshot
            } else {
                let window = state.baseTimeWindow(now: refreshedNow).flatMap {
                    MonitorTimeWindow(start: $0.start, end: state.isLiveTimeRange ? nil : $0.end)
                }
                snapshot = try await session.controlPlane.monitorRowsSnapshot(
                    window: window, previous: sameRange ? source?.snapshot : nil
                )
            }
            let evaluation = try await MonitorQueryEvaluator.evaluate(
                rows: snapshot.rows, state: state, now: refreshedNow,
                queryComplete: snapshot.isComplete, coverage: snapshot.coverage
            )
            let pinnedID = session.requestedMonitorEventID ?? pinnedEventID
            let limit = visibleLimit
            let visibleSources = Array(evaluation.displayed.prefix(limit)).map(\.source)
            let coverages = try await session.controlPlane.monitorRuleCoverage(for: visibleSources)
            let presentation = try await ActivityPresentation.build(
                evaluation: evaluation, rows: snapshot.rows, query: state, now: refreshedNow,
                coverage: snapshot.coverage, isComplete: snapshot.isComplete,
                coverages: coverages, visibleLimit: limit, pinnedID: pinnedID,
                sort: sort, includeDecisions: includeDecisions
            )
            guard windowIsVisible, MonitorQueryPublication.permits(
                requestID, active: activeQueryRequestID, taskIsCancelled: Task.isCancelled
            ) else { return }
            source = SourceCache(
                snapshot: snapshot, revision: revision, time: state.time, anchor: state.timeAnchor
            )
            publish(presentation, evaluation: evaluation, now: refreshedNow)
            rowsAreComplete = snapshot.isComplete
            historyCoverage = snapshot.coverage
            pinnedEventID = pinnedID.flatMap { id in evaluation.displayed.contains { $0.id == id } ? id : nil }
            restoreSelection()
            acceptRequestedSelection()
            loadError = nil
            signalFixtureReadiness()
        } catch is CancellationError {
        } catch {
            guard windowIsVisible, !Task.isCancelled, requestID == activeQueryRequestID else { return }
            loadError = "Rift couldn’t refresh activity. Showing what it loaded last."
        }
    }

    /// Assigns only what changed, so views that read unchanged values don't
    /// re-evaluate.
    private func publish(
        _ presentation: ActivityPresentation,
        evaluation: MonitorQueryEvaluation,
        now refreshedNow: Date
    ) {
        if now != refreshedNow { now = refreshedNow }
        if displayedCount != evaluation.displayed.count { displayedCount = evaluation.displayed.count }
        let more = evaluation.displayed.count > visibleLimit
        if hasMore != more { hasMore = more }
        if displayed != presentation.visibleRows { displayed = presentation.visibleRows }
        if summary != evaluation.summary { summary = evaluation.summary }
        if hierarchy != presentation.hierarchy { hierarchy = presentation.hierarchy }
        if rowLookup != presentation.rowLookup { rowLookup = presentation.rowLookup }
        if traffic != presentation.traffic { traffic = presentation.traffic }
        if presentation.includesDecisions, decisions != presentation.decisions {
            decisions = presentation.decisions
        }
    }

    private func signalFixtureReadiness() {
#if DEBUG
        guard session.isUIFixture else { return }
        MonitorFixtureData.signalVisualReadiness()
#endif
    }
}

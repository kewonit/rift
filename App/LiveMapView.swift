import RiftControl
import RiftCore
import SwiftUI

struct LiveMapView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var session: AppSession
    @AppStorage("liveMapTrafficChartVisible") private var showingTrafficChart = true
    @AppStorage("liveMapSummaryVisible") private var showingSummary = true
    @State private var query = MonitorQueryState(time: .tenMinutes)
    @State private var queryNow: Date
    @State private var rows: [MonitorEventRow] = []
    @State private var displayed: [MonitorDisplayRow] = []
    @State private var summary = MonitorSummarySnapshot.empty
    @State private var presentationHierarchy: [MonitorHierarchyNode] = []
    @State private var rowLookup: [String: MonitorEventRow] = [:]
    @State private var hierarchySelectionID: String?
    @State private var selectedEventID: String?
    @State private var applyingEventID: String?
    @State private var pendingManagedListOverride: MonitorHierarchyNode?
    @State private var originController: MapOriginController
    @State private var sourceSnapshot: MonitorRowsSnapshot?
    @State private var sourceRevision: UInt64?
    @State private var sourceTime: MonitorTimeFilter?
    @State private var sourceAnchor: Date?
    @State private var traffic = LiveTrafficSnapshot.empty
    @State private var refreshCoordinator = VisualRefreshCoordinator()
    @State private var windowIsVisible = false
    @State private var ready = false
    @State private var loading = false
    @State private var loadError: String?
    @State private var showingMapInformation = false
    @State private var queryTask: Task<Void, Never>?
    @State private var activeQueryRequestID = MonitorQueryRequestID()

    init(session: AppSession) {
        self.session = session
        _originController = State(initialValue: MapOriginController(persists: !session.isUIFixture))
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
        hierarchySelectionID.flatMap { MonitorHierarchyBuilder.node(withID: $0, in: hierarchy) }
    }

    private var selectedRow: MonitorEventRow? {
        guard let id = selectedNode?.eventID ?? selectedNode?.ruleSeedEventID else { return nil }
        return rows.first { $0.id == id }
    }

    var body: some View {
        observedWorkspace
    }

    private var observedWorkspace: some View {
        presentedWorkspace
            .task { await start() }
            .modifier(ActivityRefreshSignal(controller: session.controlPlane, changed: { scheduleReload() }))
            .onChange(of: session.controlPlane.persistentHistoryEnabled) { _, _ in
                sourceTime = nil; sourceSnapshot = nil; sourceRevision = nil
                if session.controlPlane.isMinimalActivity { query.selectTimeFilter(.tenMinutes); releaseActivity() }
                scheduleReload(immediate: true)
            }
            .onChange(of: query) { _, _ in scheduleQueryUpdate() }
            .background(ActivityWindowVisibility(changed: visibilityChanged))
            .onChange(of: hierarchySelectionID, handleHierarchySelection)
            .onDisappear(perform: stop)
    }

    private var presentedWorkspace: some View {
        workspace
            .toolbar { toolbar }
            .modifier(MonitorManagedListOverrideConfirmation(
                pending: $pendingManagedListOverride,
                confirm: { apply(.allow, $0, elevatedOverrideConfirmed: true) }
            ))
    }

    private var workspace: some View {
        HSplitView {
            LiveMapConnectionsPane(
                query: $query, selectionID: $hierarchySelectionID,
                displayed: displayed, hierarchy: hierarchy,
                rows: rowLookup,
                loading: loading, isMinimal: session.controlPlane.isMinimalActivity,
                artworkStore: session.applicationArtwork,
                availableLenses: MonitorLens.allCases, now: queryNow, traffic: traffic,
                applyingEventID: applyingEventID,
                showingTrafficChart: $showingTrafficChart,
                apply: { action, node in apply(action, node) },
                investigate: investigate, showRules: showRules
            )
            .frame(minWidth: 292, idealWidth: 315, maxWidth: 340, maxHeight: .infinity)

            mapWorkspace
                .frame(minWidth: 470, maxWidth: .infinity, maxHeight: .infinity)

            if showingSummary {
                MonitorSummaryView(
                    summary: summary,
                    selectedNode: selectedNode,
                    selectedRow: selectedRow,
                    applyingEventID: applyingEventID,
                    artworkStore: session.applicationArtwork,
                    apply: { action, node in apply(action, node) },
                    showRules: {
                        selectedNode.map { showRules($0.ruleCoverage.ruleIDs) }
                    },
                    hideSummary: { showingSummary = false }, isMinimal: session.controlPlane.isMinimalActivity
                )
                .frame(minWidth: 290, idealWidth: 320, maxWidth: 340, maxHeight: .infinity)
            }
        }
    }

    private var mapWorkspace: some View {
        ZStack(alignment: .topLeading) {
            OriginMapView(
                origin: $originController.origin,
                isPlacingOrigin: $originController.isPlacingManually,
                activityVisible: windowIsVisible,
                onReady: signalFixtureReadiness
            )
            if originController.origin == nil && !originController.isPlacingManually {
                ContentUnavailableView {
                    Label("Set your location", systemImage: "location.circle")
                } description: {
                    Text("Place this Mac on the map. Rift doesn’t look up your location or where connections go.")
                } actions: {
                    Button("Set My Location") { originController.beginManualPlacement() }
                }
                .frame(maxWidth: 390)
                .padding(40)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                .padding(24)
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .padding(10)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .secondaryAction) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: RiftDesign.Motion.contextual)) {
                    showingTrafficChart.toggle()
                }
            } label: {
                Label(showingTrafficChart ? "Hide Traffic Chart" : "Show Traffic Chart",
                      systemImage: "chart.bar.xaxis")
            }
            .help(showingTrafficChart ? "Hide traffic chart" : "Show traffic chart")
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: RiftDesign.Motion.contextual)) {
                    showingSummary.toggle()
                }
            } label: {
                Label(showingSummary ? "Hide Summary" : "Show Summary",
                      systemImage: "sidebar.right")
            }
            .help(showingSummary ? "Hide summary" : "Show summary")
            originMenu
            Button { showingMapInformation.toggle() } label: {
                Label("Map Information", systemImage: "info.circle")
            }
            .popover(isPresented: $showingMapInformation) { LiveMapInformation() }
        }
        ToolbarItem(placement: .primaryAction) {
            Button { scheduleReload(immediate: true) } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
    }

    private var originMenu: some View {
        LiveMapOriginControl(
            isPlacing: originController.isPlacingManually,
            hasOrigin: originController.origin != nil,
            cancelPlacement: originController.cancelPlacement,
            beginPlacement: originController.beginManualPlacement,
            clearOrigin: originController.clearOrigin
        )
    }

    private func start() async {
        guard !Task.isCancelled else { return }
#if DEBUG
        if session.isUIFixture, MonitorFixtureData.scenario != .missingOrigin,
           let coordinate = try? CoarseMapCoordinate(latitude: 37.75, longitude: -122.5) {
            originController.origin = CoarseMapOrigin(coordinate: coordinate)
        }
#endif
        ready = true
        scheduleReload(immediate: true)
    }

    private func handleHierarchySelection(_ oldValue: String?, _ value: String?) {
        guard value != nil else { return }
        selectedEventID = selectedNode?.eventID ?? selectedNode?.ruleSeedEventID
        showingSummary = true
    }

    private func visibilityChanged(_ visible: Bool) {
        guard visible != windowIsVisible else { return }
        windowIsVisible = visible
        if visible { session.controlPlane.monitorDidAppear() }
        else { session.monitorDidDisappear(); originController.cancelPlacement() }
        if !visible, session.controlPlane.isMinimalActivity { releaseActivity() }
        refreshCoordinator.setVisible(visible)
        if visible { scheduleReload(immediate: true) }
    }

    private func stop() {
        refreshCoordinator.stop()
        queryTask?.cancel()
        originController.cancelPlacement()
        if windowIsVisible { session.monitorDidDisappear() }
        if session.controlPlane.isMinimalActivity { releaseActivity() }
        windowIsVisible = false
        ready = false
    }

    private func scheduleReload(immediate: Bool = false) {
        guard ready else { return }
        if immediate { session.controlPlane.scheduleActivityDrain(immediate: true) }
        refreshCoordinator.request(immediate: immediate) { await refresh(loadSource: true) }
    }

    private func releaseActivity() {
        queryTask?.cancel()
        activeQueryRequestID = MonitorQueryRequestID()
        rows = []; displayed = []; rowLookup = [:]
        presentationHierarchy = []; summary = .empty; traffic = .empty
        sourceSnapshot = nil; sourceRevision = nil
        hierarchySelectionID = nil; selectedEventID = nil
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
        guard ready, windowIsVisible else { return }
        let interval = ActivityPerformance.signposter.beginInterval("Live Map Refresh")
        defer { ActivityPerformance.signposter.endInterval("Live Map Refresh", interval) }
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
            let refreshedCoverage = try await session.controlPlane.monitorRuleCoverage(
                for: Array(result.displayed.prefix(1_000)).map(\.source)
            )
            let presentation = try await ActivityPresentation.build(
                evaluation: result, rows: snapshot.rows, query: state, now: refreshedNow,
                coverages: refreshedCoverage, visibleLimit: 1_000
            )
            guard windowIsVisible, MonitorQueryPublication.permits(
                requestID, active: activeQueryRequestID, taskIsCancelled: Task.isCancelled
            ) else { return }
            sourceSnapshot = snapshot
            sourceRevision = revision
            sourceTime = state.time
            sourceAnchor = state.timeAnchor
            if rows != snapshot.rows { rows = snapshot.rows }
            queryNow = refreshedNow
            if displayed != result.displayed { displayed = result.displayed }
            if summary != result.summary { summary = result.summary }
            if presentationHierarchy != presentation.hierarchy { presentationHierarchy = presentation.hierarchy }
            if rowLookup != presentation.rowLookup { rowLookup = presentation.rowLookup }
            if traffic != presentation.traffic { traffic = presentation.traffic }
            restoreSelection()
            loadError = nil
            signalFixtureReadiness()
        } catch is CancellationError {
        } catch {
            guard windowIsVisible, !Task.isCancelled, requestID == activeQueryRequestID else { return }
            loadError = "Rift couldn’t refresh live activity. Existing map data is unchanged."
        }
    }

    private func restoreSelection() {
        if let selectedEventID,
           let node = MonitorHierarchyBuilder.node(forEventID: selectedEventID, in: hierarchy) {
            hierarchySelectionID = node.id
        } else if hierarchySelectionID.flatMap({
            MonitorHierarchyBuilder.node(withID: $0, in: hierarchy)
        }) == nil {
            hierarchySelectionID = nil
            selectedEventID = nil
        }
    }

    private func apply(
        _ action: FilterAction,
        _ node: MonitorHierarchyNode,
        elevatedOverrideConfirmed: Bool = false
    ) {
        guard let eventID = node.ruleSeedEventID,
              let row = rows.first(where: { $0.id == eventID }) else { return }
        applyingEventID = eventID
        Task {
            do {
                try await session.controlPlane.applyExactMonitorRule(
                    for: row, action: action,
                    elevatedOverrideConfirmed: elevatedOverrideConfirmed
                )
                loadError = nil
                refreshCoordinator.request(immediate: true) { await refresh(loadSource: false) }
            } catch ControlPlaneController.RuleCommandError.elevatedOverrideRequiresConfirmation {
                pendingManagedListOverride = node
                loadError = nil
            } catch {
                loadError = "The exact rule wasn’t applied. Retry after Rift reconnects."
            }
            applyingEventID = nil
        }
    }

    private func investigate(_ node: MonitorHierarchyNode) {
        guard let eventID = node.eventID ?? node.ruleSeedEventID
                ?? node.eventIDs.first else { return }
        session.requestedMonitorEventID = eventID
        session.destination = .activity
    }

    private func showRules(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        session.requestedRuleIDs = ids
        session.destination = .rules
    }

    private func signalFixtureReadiness() {
#if DEBUG
        guard session.isUIFixture else { return }
        MonitorFixtureData.signalVisualReadiness()
#endif
    }
}
